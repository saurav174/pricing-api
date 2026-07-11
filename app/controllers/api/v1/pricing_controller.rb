class Api::V1::PricingController < ApplicationController
  VALID_PERIODS = PricingOptions::PERIODS
  VALID_HOTELS = PricingOptions::HOTELS
  VALID_ROOMS = PricingOptions::ROOMS

  before_action :validate_params

  def index
    service = Api::V1::PricingService.new(
      period: params[:period],
      hotel: params[:hotel],
      room: params[:room]
    )

    service.run

    if service.valid?
      render json: { rate: service.result }
    else
      render json: { error: service.errors.join(', ') }, status: status_for(service)
    end
  end

  private

  def validate_params
    unless params[:period].present? && params[:hotel].present? && params[:room].present?
      return render json: { error: 'Missing required parameters: period, hotel, room' }, status: :bad_request
    end

    unless VALID_PERIODS.include?(params[:period])
      return render json: { error: "Invalid period. Must be one of: #{VALID_PERIODS.join(', ')}" }, status: :bad_request
    end

    unless VALID_HOTELS.include?(params[:hotel])
      return render json: { error: "Invalid hotel. Must be one of: #{VALID_HOTELS.join(', ')}" }, status: :bad_request
    end

    unless VALID_ROOMS.include?(params[:room])
      return render json: { error: "Invalid room. Must be one of: #{VALID_ROOMS.join(', ')}" }, status: :bad_request
    end
  end

  def status_for(service)
    case service.error_type
    when :upstream_unavailable, :rate_not_found
      :service_unavailable
    else
      :internal_server_error
    end
  end
end
