# app/models/pricing_options.rb

module PricingOptions
  PERIODS = %w[Summer Autumn Winter Spring].freeze

  HOTELS = %w[
    FloatingPointResort
    GitawayHotel
    RecursionRetreat
  ].freeze

  ROOMS = %w[
    SingletonRoom
    BooleanTwin
    RestfulKing
  ].freeze

  def self.supported_combinations
    PERIODS.product(HOTELS, ROOMS).map do |period, hotel, room|
      {
        period: period,
        hotel: hotel,
        room: room
      }
    end
  end
end# frozen_string_literal: true

