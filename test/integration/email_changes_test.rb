require "test_helper"

class EmailChangesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @methods = ENV["AUTH_METHODS"]
    ENV["AUTH_METHODS"] = "password,email_code"
    AuthRateLimit.delete_all
    ActionMailer::Base.deliveries.clear
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    sign_in @user
  end

  teardown { ENV["AUTH_METHODS"] = @methods }

  def verify_latest_code
    patch users_email_code_path, params: { code: email_code_from_last_delivery }
  end

  def security_check
    post users_security_verification_path
    verify_latest_code
  end

  test "verified email already has email-code access before a security check" do
    assert @user.auth_identities.exists?(provider: "email_code")
    assert_includes @user.available_methods, "email_code"
  end

  test "card verification enables email editing without automatically opening the modal" do
    get edit_settings_user_path(@user)
    assert_select "header.app-method-heading se-button[text='Verify identity']"
    assert_select "se-button[data-open-email-modal][disabled]"
    post users_security_verification_path
    assert_redirected_to users_email_code_path
    verify_latest_code
    assert_redirected_to edit_settings_user_path(@user)
    follow_redirect!
    assert_select "se-modal#email-modal[open]", count: 0
    assert_select "se-button[data-open-email-modal]:not([disabled])"
    assert_select "se-badge[text='Security check complete']", count: 0
    post users_security_verification_path, params: { next: "https://example.com" }
    assert_redirected_to edit_settings_user_path(@user)
  end

  test "security proof does not enable a disabled email code method" do
    ENV["AUTH_METHODS"] = "password"
    security_check
    assert_not_includes @user.available_methods, "email_code"
  end

  test "email change requires security proof and then proof of the new address" do
    post users_change_email_path, params: { user: { email: "replacement@example.com" } }
    assert_redirected_to edit_settings_user_path(@user)
    assert_empty ActionMailer::Base.deliveries
    security_check
    old_challenge, = EmailChallenge.issue!(email: @user.email, purpose: "login")
    @user.send_reset_password_instructions
    post users_change_email_path, params: { user: { email: "REPLACEMENT@example.com" } }
    assert_redirected_to users_email_code_path
    assert_equal "one@example.com", @user.reload.email
    assert_equal ["replacement@example.com"], ActionMailer::Base.deliveries.last.to
    patch users_email_code_path, params: { code: "bad" }
    assert_response :unprocessable_entity
    assert_equal "one@example.com", @user.reload.email
    assert_no_difference "User.count" do
      verify_latest_code
    end
    assert_redirected_to edit_settings_user_path(@user)
    assert_equal "replacement@example.com", @user.reload.email
    assert @user.email_verified_at
    assert_nil @user.reset_password_token
    assert_not EmailChallenge.exists?(old_challenge.id)
    assert_equal %w[email_code password], @user.available_methods.sort
    verify_latest_code
    assert_response :unprocessable_entity
  end

  test "email change cannot take an existing email even if claimed after requesting a code" do
    security_check
    post users_change_email_path, params: { user: { email: "claimed@example.com" } }
    User.register_verified!(email: "claimed@example.com", method: "email_code")
    verify_latest_code
    assert_response :unprocessable_entity
    assert_equal "one@example.com", @user.reload.email
  end

  test "email change is bound to the current user and recent security proof" do
    security_check
    post users_change_email_path, params: { user: { email: "replacement@example.com" } }
    other = users(:two)
    other.update!(email_verified_at: Time.current)
    sign_in other
    verify_latest_code
    assert_response :unprocessable_entity
    assert_equal "one@example.com", @user.reload.email
    sign_in @user
    travel 11.minutes do
      verify_latest_code
      assert_response :unprocessable_entity
    end
    assert_equal "one@example.com", @user.reload.email
  end

  test "admin cannot change another users email through the self-service endpoint" do
    security_check
    post users_change_email_path, params: { id: users(:two).id, user: { email: "my-new@example.com" } }
    verify_latest_code
    assert_equal "my-new@example.com", @user.reload.email
    assert_equal "two@example.com", users(:two).reload.email
  end
end
