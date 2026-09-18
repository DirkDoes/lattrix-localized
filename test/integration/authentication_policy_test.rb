require "test_helper"

class AuthenticationPolicyTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @methods = ENV["AUTH_METHODS"]
    ENV["AUTH_METHODS"] = "password,email_code,google,github,discord"
    AuthRateLimit.delete_all
    ActionMailer::Base.deliveries.clear
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    %w[google github discord].each { |provider| @user.auth_identities.create!(provider: provider, provider_uid: "policy-#{provider}") }
  end

  teardown { ENV["AUTH_METHODS"] = @methods }

  def security_check
    post users_security_verification_path
    patch users_email_code_path, params: { code: ActionMailer::Base.deliveries.last.body.decoded[/\b\d{6}\b/] }
  end

  test "settings hide disabled methods and direct mutations cannot use them" do
    sign_in @user
    security_check
    %w[password email_code google github discord].each do |enabled|
      ENV["AUTH_METHODS"] = enabled
      get edit_settings_user_path(@user, connect: enabled == "google" ? "discord" : "google")
      assert_response :success
      assert_select "se-modal#connect-provider-modal", count: 0
      assert_select "se-modal#password-modal", count: enabled == "password" ? 1 : 0
      assert_select ".app-method-list .app-method-row", count: enabled == "email_code" ? 1 : 2
      assert_equal [enabled], @user.available_methods
      (%w[password email_code google github discord] - [enabled]).each do |disabled|
        assert_no_difference "AuthIdentity.count" do
          post link_authentication_method_path(disabled)
          assert_response :not_found
          delete authentication_methods_path, params: { provider: disabled }
          assert_response :not_found
        end
      end
      next if enabled == "password"
      patch authentication_methods_path, params: { user: { password: "Changed123!", password_confirmation: "Changed123!" } }
      assert_response :not_found
    end
  end

  test "pending login code stops working when email code is disabled" do
    post users_email_code_path, params: { user: { email: @user.email } }
    code = ActionMailer::Base.deliveries.last.body.decoded[/\b\d{6}\b/]
    ENV["AUTH_METHODS"] = "password"
    patch users_email_code_path, params: { code: code }
    assert_response :unprocessable_entity
    get overview_path
    assert_redirected_to new_user_session_path
  end

  test "password recovery tokens cannot bypass disabled passwords" do
    token = @user.send_reset_password_instructions
    original = @user.encrypted_password
    ENV["AUTH_METHODS"] = "email_code"
    get edit_user_password_path(reset_password_token: token)
    assert_response :not_found
    patch user_password_path, params: { user: { reset_password_token: token, password: "Changed123!", password_confirmation: "Changed123!" } }
    assert_response :not_found
    assert_not @user.reload.reset_password("Changed123!", "Changed123!")
    assert_equal original, @user.reload.encrypted_password
  end

  test "pending password registration cannot complete after passwords are disabled" do
    post user_registration_path, params: { user: { email: "pending-policy@example.com", password: "Password123!", password_confirmation: "Password123!" } }
    code = ActionMailer::Base.deliveries.last.body.decoded[/\b\d{6}\b/]
    ENV["AUTH_METHODS"] = "email_code"
    assert_no_difference "User.count" do
      patch users_email_code_path, params: { code: code }
    end
    assert_response :unprocessable_entity
  end

  test "admins cannot grant ownership or edit owners" do
    admin = users(:two)
    admin.update!(email_verified_at: Time.current)
    @user.update!(role: :owner)
    sign_in admin
    patch settings_user_path(admin), params: { user: { role: "owner" } }
    assert_response :unprocessable_entity
    assert admin.reload.admin?
    patch settings_user_path(@user), params: { user: { name: "Hijacked", role: "guest" } }
    assert_redirected_to settings_users_path
    assert @user.reload.owner?
    assert_equal "One User", @user.name
  end

  test "reusing a valid security check does not extend its lifetime" do
    sign_in @user
    security_check
    travel 9.minutes do
      assert_no_difference "ActionMailer::Base.deliveries.size" do
        post users_security_verification_path
      end
    end
    travel 11.minutes do
      get edit_settings_user_path(@user)
      assert_select "se-button[data-open-email-modal][disabled]"
    end
  end

  test "changing email invalidates security proof in another session" do
    sign_in @user
    security_check
    @user.update!(email: "new-primary@example.com", password_optional: true)
    patch authentication_methods_path, params: { user: { password: "Changed123!", password_confirmation: "Changed123!" } }
    assert_redirected_to edit_settings_user_path(@user)
    assert @user.reload.valid_password?("Password123!")
  end

  test "unverified accounts cannot use password sign-in or trigger a legacy verification email" do
    @user.update!(email_verified_at: nil)
    post user_session_path, params: { user: { email: @user.email, password: "Password123!" } }
    assert_empty ActionMailer::Base.deliveries
    get overview_path
    assert_redirected_to new_user_session_path
  end

  test "new passwords reject short values and bcrypt byte truncation" do
    original = @user.encrypted_password
    assert_not @user.update(password: "short1", password_confirmation: "short1")
    @user.reload
    password = "é" * 40
    assert_not @user.update(password: password, password_confirmation: password)
    assert_includes @user.errors[:password], "must be at most 72 bytes"
    assert_equal original, @user.reload.encrypted_password
  end
end
