module Api::V1
  class PricingService < BaseService
    CACHE_TTL = 5.minutes
    FAILURE_COOLDOWN = 10.seconds

    UpstreamUnavailableError = Class.new(StandardError)

    NETWORK_ERRORS = [
      HTTParty::Error,
      SocketError,
      Timeout::Error,
      Errno::ECONNREFUSED,
      Net::OpenTimeout,
      Net::ReadTimeout
    ].freeze

    @rates = {}
    @fetched_at = nil
    @last_refresh_failed_at = nil
    @refresh_mutex = Mutex.new

    attr_reader :result, :error_type

    class << self
      def supported_combinations
        PricingOptions.supported_combinations
      end

      def rate_for(period:, hotel:, room:)
        @rates[cache_key(period: period, hotel: hotel, room: room)]
      end

      def ensure_fresh_cache!
        return if cache_fresh?

        raise_if_refresh_recently_failed!

        @refresh_mutex.synchronize do
          # Another request may have refreshed the cache while this request was waiting.
          return if cache_fresh?

          raise_if_refresh_recently_failed!

          refresh_cache!
        end
      end

      def cache_key(period:, hotel:, room:)
        [hotel, room, period].join('|')
      end


      private

      def cache_fresh?
        @fetched_at.present? && @fetched_at > CACHE_TTL.ago
      end

      def refresh_recently_failed?
        @last_refresh_failed_at.present? && @last_refresh_failed_at > FAILURE_COOLDOWN.ago
      end

      def raise_if_refresh_recently_failed!
        return unless refresh_recently_failed?

        raise UpstreamUnavailableError, 'Pricing model is temporarily unavailable. Please try again later.'
      end

      def refresh_cache!
        Rails.logger.info('[pricing] cache_refresh_start')

        response = fetch_rates_from_upstream
        validate_successful_response!(response)

        fresh_rates = build_rate_table(response.body)
        replace_cache!(fresh_rates)

        Rails.logger.info("[pricing] cache_refresh_success rates_count=#{@rates.size}")
      rescue UpstreamUnavailableError => e
        remember_refresh_failure
        Rails.logger.warn("[pricing] cache_refresh_failed reason=#{e.message.inspect}")
        raise
      rescue JSON::ParserError
        remember_refresh_failure
        Rails.logger.warn('[pricing] cache_refresh_failed reason="invalid_json"')
        raise UpstreamUnavailableError, 'Pricing model returned an invalid response.'
      rescue *NETWORK_ERRORS => e
        remember_refresh_failure
        Rails.logger.warn("[pricing] cache_refresh_failed error_class=#{e.class.name} message=#{e.message.inspect}")
        raise UpstreamUnavailableError, 'Pricing model is unavailable. Please try again later.'
      end

      def fetch_rates_from_upstream
        RateApiClient.get_rates(attributes: supported_combinations)
      end

      def validate_successful_response!(response)
        return if response.success?

        raise UpstreamUnavailableError, upstream_error_message(response)
      end

      def build_rate_table(response_body)
        parsed_body = parse_response_body(response_body)
        rates = parsed_body['rates'] || parsed_body[:rates]

        unless rates.is_a?(Array)
          raise UpstreamUnavailableError, 'Pricing model response did not include rates.'
        end

        rate_table = rates.each_with_object({}) do |rate, table|
          rate_key = cache_key_from_rate(rate)
          rate_value = value_from(rate, :rate)

          next if rate_key.nil? || rate_value.nil?

          table[rate_key] = rate_value
        end

        validate_complete_rate_table!(rate_table)

        rate_table
      end

      def cache_key_from_rate(rate)
        period = value_from(rate, :period)
        hotel = value_from(rate, :hotel)
        room = value_from(rate, :room)

        return if period.blank? || hotel.blank? || room.blank?

        cache_key(period: period, hotel: hotel, room: room)
      end

      def validate_complete_rate_table!(rate_table)
        missing_keys = expected_cache_keys - rate_table.keys

        return if missing_keys.empty?

        Rails.logger.warn("[pricing] incomplete_rate_response missing_count=#{missing_keys.size}")
        raise UpstreamUnavailableError, 'Pricing model response was incomplete.'
      end

      def expected_cache_keys
        supported_combinations.map { |attributes| cache_key(**attributes) }
      end

      def replace_cache!(fresh_rates)
        @rates = fresh_rates
        @fetched_at = Time.current
        @last_refresh_failed_at = nil
      end

      def parse_response_body(body)
        body.is_a?(Hash) ? body : JSON.parse(body)
      end

      def value_from(hash, key)
        hash[key.to_s] || hash[key]
      end

      def upstream_error_message(response)
        body = parse_response_body(response.body)
        body['error'] || body[:error] || 'Pricing model failed to return rates.'
      rescue JSON::ParserError
        'Pricing model failed to return rates.'
      end

      def remember_refresh_failure
        @last_refresh_failed_at = Time.current
      end
    end

    def initialize(period:, hotel:, room:)
      @period = period
      @hotel = hotel
      @room = room
      @result = nil
      @error_type = nil
    end

    def run
      self.class.ensure_fresh_cache!

      @result = self.class.rate_for(
        period: @period,
        hotel: @hotel,
        room: @room
      )

      if @result.nil?
        Rails.logger.warn("[pricing] rate_not_found period=#{@period} hotel=#{@hotel} room=#{@room}")
        add_error(:rate_not_found, 'Rate was not found for the requested criteria.')
      else
        Rails.logger.info("[pricing] cache_hit period=#{@period} hotel=#{@hotel} room=#{@room}")
      end
    rescue UpstreamUnavailableError => e
      add_error(:upstream_unavailable, e.message)
    end

    private

    def add_error(type, message)
      @error_type = type
      errors << message
    end
  end
end