require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  setup do
    reset_pricing_cache!
  end

  test "should get pricing with all parameters" do
    mock_response = rates_response(
      "FloatingPointResort|SingletonRoom|Summer" => "15000"
    )

    RateApiClient.stub(:get_rates, mock_response) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :success
      assert_equal "application/json", @response.media_type

      json_response = JSON.parse(@response.body)
      assert_equal "15000", json_response["rate"]
    end
  end

  test "should reuse cached rates on subsequent requests" do
    upstream_calls = 0
    mock_response = rates_response(
      "FloatingPointResort|SingletonRoom|Summer" => "15000"
    )

    RateApiClient.stub(:get_rates, lambda { |**_args|
      upstream_calls += 1
      mock_response
    }) do
      get api_v1_pricing_url, params: pricing_params
      assert_response :success

      get api_v1_pricing_url, params: pricing_params
      assert_response :success
      assert_equal 1, upstream_calls
    end
  end

  test "should return error when rate API fails" do
    mock_response = OpenStruct.new(success?: false, body: { "error" => "Rate not found" })

    RateApiClient.stub(:get_rates, mock_response) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :service_unavailable
      assert_equal "application/json", @response.media_type

      json_response = JSON.parse(@response.body)
      assert_includes json_response["error"], "Rate not found"
    end
  end

  test "should return error when upstream response is incomplete" do
    mock_response = OpenStruct.new(
      success?: true,
      body: {
        "rates" => [
          { "period" => "Summer", "hotel" => "FloatingPointResort", "room" => "SingletonRoom", "rate" => "15000" }
        ]
      }
    )

    RateApiClient.stub(:get_rates, mock_response) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :service_unavailable

      json_response = JSON.parse(@response.body)
      assert_includes json_response["error"], "incomplete"
    end
  end

  test "should return error when upstream response has no rates" do
    mock_response = OpenStruct.new(success?: true, body: { "rates" => "nope" })

    RateApiClient.stub(:get_rates, mock_response) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :service_unavailable

      json_response = JSON.parse(@response.body)
      assert_includes json_response["error"], "did not include rates"
    end
  end

  test "should return error when upstream response is invalid json" do
    mock_response = OpenStruct.new(success?: true, body: "totally not json")

    RateApiClient.stub(:get_rates, mock_response) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :service_unavailable

      json_response = JSON.parse(@response.body)
      assert_includes json_response["error"], "invalid response"
    end
  end

  test "should return error when upstream request times out" do
    RateApiClient.stub(:get_rates, lambda { |**_args|
      raise Net::ReadTimeout, "execution expired"
    }) do
      get api_v1_pricing_url, params: pricing_params

      assert_response :service_unavailable

      json_response = JSON.parse(@response.body)
      assert_includes json_response["error"], "unavailable"
    end
  end

  test "should not retry upstream immediately after a failed refresh" do
    upstream_calls = 0
    mock_response = OpenStruct.new(success?: false, body: { "error" => "Service down" })

    RateApiClient.stub(:get_rates, lambda { |**_args|
      upstream_calls += 1
      mock_response
    }) do
      get api_v1_pricing_url, params: pricing_params
      assert_response :service_unavailable

      get api_v1_pricing_url, params: pricing_params
      assert_response :service_unavailable
      assert_equal 1, upstream_calls

      json_response = JSON.parse(@response.body)
      assert_includes json_response["error"], "temporarily unavailable"
    end
  end

  test "should return error when requested rate is missing from cache" do
    mock_response = rates_response(
      "FloatingPointResort|SingletonRoom|Summer" => "15000"
    )

    RateApiClient.stub(:get_rates, mock_response) do
      get api_v1_pricing_url, params: pricing_params
      assert_response :success
    end

    rates = Api::V1::PricingService.instance_variable_get(:@rates)
    rates.delete("FloatingPointResort|SingletonRoom|Summer")

    get api_v1_pricing_url, params: pricing_params

    assert_response :service_unavailable

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Rate was not found"
  end

  test "should return error without any parameters" do
    get api_v1_pricing_url

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Missing required parameters"
  end

  test "should handle empty parameters" do
    get api_v1_pricing_url, params: {
      period: "",
      hotel: "",
      room: ""
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Missing required parameters"
  end

  test "should reject invalid period" do
    get api_v1_pricing_url, params: pricing_params(period: "summer-2024")

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid period"
  end

  test "should reject invalid hotel" do
    get api_v1_pricing_url, params: pricing_params(hotel: "InvalidHotel")

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid hotel"
  end

  test "should reject invalid room" do
    get api_v1_pricing_url, params: pricing_params(room: "InvalidRoom")

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid room"
  end

  private

  def pricing_params(overrides = {})
    {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }.merge(overrides)
  end

  def rates_response(overrides = {})
    rates = PricingOptions.supported_combinations.map do |combo|
      cache_key = Api::V1::PricingService.cache_key(**combo)

      {
        "period" => combo[:period],
        "hotel" => combo[:hotel],
        "room" => combo[:room],
        "rate" => overrides.fetch(cache_key, "9999")
      }
    end

    OpenStruct.new(success?: true, body: { "rates" => rates })
  end

  def reset_pricing_cache!
    Api::V1::PricingService.instance_variable_set(:@rates, {})
    Api::V1::PricingService.instance_variable_set(:@fetched_at, nil)
    Api::V1::PricingService.instance_variable_set(:@last_refresh_failed_at, nil)
  end
end
