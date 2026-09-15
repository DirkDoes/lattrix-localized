require "test_helper"

class CodeRateLimitsTest < ActionDispatch::IntegrationTest
  setup do
    @methods = ENV["AUTH_METHODS"]
    ENV["AUTH_METHODS"] = "email_code,password"
    AuthRateLimit.delete_all
  end

  teardown { ENV["AUTH_METHODS"] = @methods }

  test "code cooldown is thirty seconds and reports the remaining wait" do
    travel_to Time.utc(2026, 9, 14, 12, 0, 0) do
      post users_email_code_path, params: { user: { email: "cooldown@example.com" } }
      travel 10.seconds
      post users_email_code_path, params: { user: { email: "cooldown@example.com" } }
      assert_response :too_many_requests
      assert_equal "20", response.headers["Retry-After"]
      assert_includes response.body, "Please wait 20 seconds before you can send another request."
      travel 20.seconds
      assert_difference "ActionMailer::Base.deliveries.size", 1 do
        post users_email_code_path, params: { user: { email: "cooldown@example.com" } }
      end
      assert_redirected_to users_email_code_path
    end
  end

  test "hourly cap reports its longer wait and blocked retries do not consume quota" do
    travel_to Time.utc(2026, 9, 14, 12, 0, 0) do
      5.times do
        AuthRateLimit.request!("test-ip", "hourly@example.com")
        error = assert_raises(AuthRateLimit::Exceeded) { AuthRateLimit.request!("test-ip", "hourly@example.com") }
        assert error.retry_after.positive?
        travel 30.seconds
      end
      error = assert_raises(AuthRateLimit::Exceeded) { AuthRateLimit.request!("test-ip", "hourly@example.com") }
      assert_equal 3450, error.retry_after
      assert_equal "Please wait 57 minutes and 30 seconds before you can send another request.", error.message
    end
  end
end
