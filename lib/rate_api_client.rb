class RateApiClient
  include HTTParty

  base_uri ENV.fetch('RATE_API_URL', 'http://localhost:8080')
  headers 'Content-Type' => 'application/json'
  headers 'token' => ENV.fetch('RATE_API_TOKEN', '04aa6f42aa03f220c2ae9a276cd68c62')

  DEFAULT_TIMEOUT_SECONDS = 2

  class << self
    def get_rates(attributes:)
      post('/pricing', body: { attributes: attributes }.to_json, timeout: timeout_seconds)
    end

    private

    def timeout_seconds
      Integer(ENV.fetch('RATE_API_TIMEOUT_SECONDS', DEFAULT_TIMEOUT_SECONDS))
    rescue ArgumentError
      DEFAULT_TIMEOUT_SECONDS
    end
  end
end