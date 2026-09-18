require "test_helper"

class AuthenticationFlowsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @old_methods = ENV["AUTH_METHODS"]
    ENV["AUTH_METHODS"] = "password,email_code"
    ActionMailer::Base.deliveries.clear
    AuthRateLimit.delete_all
    EmailChallenge.delete_all
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
  end

  teardown do
    ENV["AUTH_METHODS"] = @old_methods
  end

  def code_from_mail
    ActionMailer::Base.deliveries.last.body.decoded[/\b\d{6}\b/]
  end

  test "email registration waits for proof and code cannot be replayed" do
    assert_no_difference "User.count" do
      post users_email_code_path, params: { user: { email: "NEW@example.com" } }
    end
    assert_redirected_to users_email_code_path
    code = code_from_mail
    assert_difference "User.count", 1 do
      patch users_email_code_path, params: { code: code }
    end
    assert_redirected_to overview_path
    user = User.find_by!(email: "new@example.com")
    assert user.email_verified_at
    assert_match(/\A[0-9a-f-]{36}\z/, user.id)
    patch users_email_code_path, params: { code: code }
    assert_response :unprocessable_entity
  end

  test "wrong code budget and expiry are enforced" do
    challenge, code = EmailChallenge.issue!(email: @user.email, purpose: "login")
    5.times { assert_raises(EmailChallenge::Invalid) { challenge.consume!("bad") } }
    assert_raises(EmailChallenge::Invalid) { challenge.consume!(code) }
    other, code = EmailChallenge.issue!(email: @user.email, purpose: "login")
    other.update!(expires_at: 1.second.ago)
    assert_raises(EmailChallenge::Invalid) { other.consume!(code) }
  end

  test "resend invalidates the previous challenge" do
    old, code = EmailChallenge.issue!(email: @user.email, purpose: "login")
    fresh, fresh_code = EmailChallenge.issue!(email: @user.email, purpose: "login")
    assert_not EmailChallenge.exists?(old.id)
    assert_raises(EmailChallenge::Invalid) { fresh.consume!(code == fresh_code ? "bad" : code) }
    assert fresh.consume!(fresh_code)
  end

  test "email login reuses an existing password account" do
    post users_email_code_path, params: { user: { email: @user.email.upcase } }
    assert_no_difference "User.count" do
      patch users_email_code_path, params: { code: code_from_mail }
    end
    assert_redirected_to overview_path
    get edit_settings_user_path(@user)
    assert_response :success
  end

  test "password registration persists only after email verification" do
    assert_no_difference "User.count" do
      post user_registration_path, params: { user: { email: "password-new@example.com", password: "SecurePassword123!", password_confirmation: "SecurePassword123!" } }
    end
    assert_redirected_to users_email_code_path
    patch users_email_code_path, params: { code: code_from_mail }
    user = User.find_by!(email: "password-new@example.com")
    assert user.valid_password?("SecurePassword123!")
  end


  test "disabled email codes and password endpoints reject requests" do
    ENV["AUTH_METHODS"] = "password"
    post users_email_code_path, params: { user: { email: @user.email } }
    assert_response :not_found
    ENV["AUTH_METHODS"] = "email_code"
    post user_session_path, params: { user: { email: @user.email, password: "Password123!" } }
    assert_response :not_found
    post user_password_path, params: { user: { email: @user.email } }
    assert_response :not_found
  end

  test "security verification is required and last method cannot be removed" do
    sign_in @user
    patch authentication_methods_path, params: { user: { password: "Changed123!", password_confirmation: "Changed123!" } }
    assert @user.reload.valid_password?("Password123!")
    post users_security_verification_path
    patch users_email_code_path, params: { code: code_from_mail }
    ENV["AUTH_METHODS"] = "password"
    delete authentication_methods_path, params: { provider: "password" }
    assert @user.reload.valid_password?("Password123!")
    ENV["AUTH_METHODS"] = "password,email_code"
    delete authentication_methods_path, params: { provider: "password" }
    assert_empty @user.reload.encrypted_password
  end

  test "ban denies application access but allows password and email authentication and sign out" do
    sign_in @user
    @user.update!(banned_at: Time.current)
    get overview_path
    assert_response :forbidden
    get settings_users_path
    assert_response :forbidden
    patch settings_user_path(@user), params: { user: { name: "Unauthorized edit" } }
    assert_response :forbidden
    assert_equal "One User", @user.reload.name
    post users_security_verification_path
    assert_response :forbidden
    delete destroy_user_session_path
    assert_response :redirect
    post user_session_path, params: { user: { email: @user.email, password: "Password123!" } }
    assert_redirected_to overview_path
    get overview_path
    assert_response :forbidden
    assert_select "se-badge[text='Access suspended']"
    delete destroy_user_session_path
    post users_email_code_path, params: { user: { email: @user.email } }
    patch users_email_code_path, params: { code: code_from_mail }
    assert_redirected_to overview_path
    get overview_path
    assert_response :forbidden
    @user.update!(banned_at: nil)
    get overview_path
    assert_response :success
  end

  test "admin cannot modify another users credentials or appearance" do
    admin = users(:two)
    admin.update!(email_verified_at: Time.current)
    sign_in admin
    patch settings_user_path(@user), params: { user: { name: "Renamed", email: "stolen@example.com", password: "hacked", theme_preference: "dark", role: "guest" } }
    assert_equal "Renamed", @user.reload.name
    assert_equal "one@example.com", @user.email
    assert_equal "system", @user.theme_preference
    assert @user.valid_password?("Password123!")
    get edit_settings_user_path(@user)
    assert_response :success
    assert_select "form[action=?]", users_security_verification_path, count: 0
  end

  test "last active owner cannot be banned demoted or deleted" do
    @user.update!(role: :owner)
    assert_not @user.update(role: :guest)
    @user.reload
    assert_not @user.update(banned_at: Time.current)
    @user.reload
    assert_not @user.destroy
  end

  test "request throttle is durable and prevents repeated mail" do
    post users_email_code_path, params: { user: { email: @user.email } }
    post users_email_code_path, params: { user: { email: @user.email } }
    assert_response :too_many_requests
    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  test "normalized email uniqueness is enforced by the database" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      User.insert_all!([{ email: @user.email.upcase, name: "Duplicate", role: 0, theme_preference: "system" }])
    end
  end



  test "sign-in choices and password modal use components without exposing development codes" do
    get new_user_session_path
    assert_select "se-segmented-control[aria-label='Email sign-in method']", count: 1
    post users_email_code_path, params: { user: { email: @user.email } }
    code = code_from_mail
    get users_email_code_path
    assert_no_match code, response.body
    assert_no_match "Development code", response.body
    patch users_email_code_path, params: { code: code }
    get edit_settings_user_path(@user)
    assert_select "se-modal#password-modal"
    assert_select "se-badge[text='Enabled']"
    assert_select "se-badge[text='Email verified']"
    assert_select "se-button[data-open-email-modal]:not([disabled])"
    assert_select "form[action*='provider=email_code']", count: 0
    assert_select "se-button[data-open-password-modal]:not([disabled])"
    patch authentication_methods_path, params: { user: { password: "", password_confirmation: "" } }
    assert_response :unprocessable_entity
    assert_select "se-modal[open] se-input[error=?]", "can't be blank"
  end

  test "active and banned user lists are separated" do
    admin = users(:two)
    admin.update!(email_verified_at: Time.current)
    @user.update!(banned_at: Time.current)
    sign_in admin
    get settings_users_path
    assert_select "se-list-row", text: /One User/, count: 0
    get settings_users_path(status: "banned")
    assert_select "se-list-row", text: /One User/, count: 1
    assert_select "se-badge[text='Banned']", count: 0
  end



end
