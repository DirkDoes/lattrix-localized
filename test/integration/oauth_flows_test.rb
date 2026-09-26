require "test_helper"
require "minitest/mock"

class OauthFlowsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @old_methods = ENV["AUTH_METHODS"]
    ENV["AUTH_METHODS"] = "password,email_code,google,github,discord"
    @old_test_mode = OmniAuth.config.test_mode
    OmniAuth.config.test_mode = true
    AuthRateLimit.delete_all
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    ENV["AUTH_METHODS"] = @old_methods
    OmniAuth.config.test_mode = @old_test_mode
    OmniAuth.config.mock_auth.clear
  end

  def provider_auth(provider, email: "external@example.com", uid: "account-123", verified: true, image: nil)
    strategy = AuthenticationPolicy::PROVIDERS.fetch(provider)
    OmniAuth.config.mock_auth[strategy.to_sym] = OmniAuth::AuthHash.new(
      provider: strategy, uid: uid, info: { email: email, name: "External User", image: image },
      extra: { raw_info: { email_verified: verified, verified: verified },
        all_emails: [{ "email" => email, "primary" => true, "verified" => verified }] })
    post "/users/auth/#{strategy}"
    assert_response :redirect
    follow_redirect!
  end

  test "verified providers create UUID accounts and existing identities reuse them" do
    %w[google github discord].each do |provider|
      assert_difference "User.count", 1 do
        provider_auth(provider, email: "#{provider}@example.com")
      end
      assert_redirected_to projects_path
      user = User.find_by!(email: "#{provider}@example.com")
      assert_equal ["email_code", provider].sort, user.auth_identities.pluck(:provider).sort
      assert_equal "External User", user.auth_identities.find_by!(provider: provider).display_name
      assert_empty user.encrypted_password
      get edit_settings_user_path(user)
      assert_select "se-text", text: "Email-code sign-in is enabled."
      assert_select "se-button[text='Verify identity']"
      sign_out user
      assert_no_difference "User.count" do
        provider_auth(provider, email: "changed-#{provider}@example.com")
      end
      assert_redirected_to projects_path
      sign_out user
    end
  end

  test "all verified provider registrations import photos and respect removal on subsequent login" do
    png = Vips::Image.black(16, 16).pngsave_buffer
    %w[google github discord].each do |provider|
      ProfilePhoto.stub(:fetch, png) do
        provider_auth(provider, email: "photo-#{provider}@example.com", image: "https://example.com/avatar")
      end
      assert_redirected_to projects_path
      user = User.find_by!(email: "photo-#{provider}@example.com")
      assert user.profile_photo.present?
      delete profile_photo_path
      assert user.reload.profile_photo_customized?
      sign_out user
      ProfilePhoto.stub(:fetch, ->(*) { flunk "Removed photo must stay removed" }) do
        provider_auth(provider, email: user.email, image: "https://example.com/avatar")
      end
      assert_redirected_to projects_path
      assert_nil user.reload.profile_photo
      sign_out user
    end
  end

  test "unverified provider email cannot register" do
    %w[google github discord].each do |provider|
      assert_no_difference "User.count" do
        provider_auth(provider, verified: false)
      end
      assert_redirected_to new_user_session_path
    end
  end

  test "matching email does not silently link an existing account" do
    assert_no_difference "AuthIdentity.count" do
      provider_auth("google", email: @user.email)
    end
    assert_redirected_to new_user_session_path
  end

  test "explicit link requires email proof and can use a different provider email" do
    sign_in @user
    post link_authentication_method_path("discord")
    assert_redirected_to edit_settings_user_path(@user)
    post users_security_verification_path
    code = ActionMailer::Base.deliveries.last.body.decoded[/\b\d{6}\b/]
    patch users_email_code_path, params: { code: code }
    post link_authentication_method_path("discord")
    assert_redirected_to edit_settings_user_path(@user, connect: "discord")
    follow_redirect!
    assert_select "se-modal#connect-provider-modal[open] form[action='/users/auth/discord'][method='post']"
    assert_select "se-modal#connect-provider-modal > se-button[data-se-region=footer][data-modal-action=confirm][text=Continue]"
    assert_no_difference "User.count" do
      provider_auth("discord", email: "different@example.com")
    end
    assert_redirected_to edit_settings_user_path(@user)
    assert @user.auth_identities.exists?(provider: "discord")
    assert_equal "one@example.com", @user.reload.email
    delete authentication_methods_path, params: { provider: "discord" }
    assert_not @user.auth_identities.exists?(provider: "discord")
  end

  test "an external identity cannot be linked to two accounts" do
    @user.auth_identities.create!(provider: "github", provider_uid: "account-123")
    other = users(:two)
    other.update!(email_verified_at: Time.current)
    sign_in other
    post users_security_verification_path
    code = ActionMailer::Base.deliveries.last.body.decoded[/\b\d{6}\b/]
    patch users_email_code_path, params: { code: code }
    post link_authentication_method_path("github")
    assert_no_difference "AuthIdentity.count" do
      provider_auth("github")
    end
    assert_equal @user.id, AuthIdentity.find_by!(provider: "github").user_id
    assert_redirected_to edit_settings_user_path(other)
    assert_equal "This GitHub account is already connected to a different account.", flash[:alert]
    follow_redirect!
    assert_response :success
    assert_no_match "You are already signed in", response.body
  end

  test "unverified emails cannot link even from a verified session" do
    sign_in @user
    post users_security_verification_path
    code = ActionMailer::Base.deliveries.last.body.decoded[/\b\d{6}\b/]
    patch users_email_code_path, params: { code: code }
    %w[google github discord].each do |provider|
      post link_authentication_method_path(provider)
      assert_no_difference "AuthIdentity.count" do
        provider_auth(provider, verified: false)
      end
      assert_redirected_to edit_settings_user_path(@user)
      assert_match "verified email", flash[:alert]
    end
  end

  test "banned identities authenticate without app access and disabled callbacks are rejected" do
    @user.auth_identities.create!(provider: "google", provider_uid: "account-123")
    @user.update!(banned_at: Time.current)
    provider_auth("google")
    assert_redirected_to projects_path
    get projects_path
    assert_response :forbidden
    sign_out @user
    ENV["AUTH_METHODS"] = "password"
    provider_auth("google")
    assert_response :not_found
  end

  test "new provider accounts receive access as guests" do
    provider_auth("github", email: "new-provider@example.com")
    assert_redirected_to projects_path
    get projects_path
    assert_response :success
    assert User.find_by!(email: "new-provider@example.com").guest?
  end

  test "provider signup can immediately use email code without a separate security check" do
    provider_auth("google", email: "google-code@example.com")
    user = User.find_by!(email: "google-code@example.com")
    sign_out user
    post users_email_code_path, params: { user: { email: user.email } }
    assert_no_difference "User.count" do
      patch users_email_code_path, params: { code: ActionMailer::Base.deliveries.last.body.decoded[/\b\d{6}\b/] }
    end
    assert_redirected_to projects_path
  end
end
