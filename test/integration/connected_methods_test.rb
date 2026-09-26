require "test_helper"

class ConnectedMethodsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @methods = ENV["AUTH_METHODS"]
    ENV["AUTH_METHODS"] = "password,email_code"
    AuthRateLimit.delete_all
    ActionMailer::Base.deliveries.clear
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
  end

  teardown { ENV["AUTH_METHODS"] = @methods }

  def submit_code
    patch users_email_code_path, params: { code: ActionMailer::Base.deliveries.last.body.decoded[/\b\d{6}\b/] }
  end

  test "password signup verifies email and also connects email code after proof" do
    post user_registration_path, params: { user: { name: "New Person", email: "new-password@example.com", password: "Password123!", password_confirmation: "Password123!" } }
    assert_redirected_to users_email_code_path
    assert_not User.exists?(email: "new-password@example.com")
    submit_code
    user = User.find_by!(email: "new-password@example.com")
    assert_equal %w[email_code password], user.available_methods.sort
    assert user.email_verified_at
    assert user.guest?
    get projects_path
    assert_response :success
    post link_authentication_method_path("email_code")
    assert user.reload.available_methods.include?("email_code")
  end

  test "duplicate password registration never overwrites credentials or reveals existence before proof" do
    original = @user.encrypted_password
    post user_registration_path, params: { user: { email: @user.email, password: "Different123!", password_confirmation: "Different123!" } }
    assert_redirected_to users_email_code_path
    assert_no_difference "User.count" do
      submit_code
    end
    assert_redirected_to new_user_session_path
    assert_equal original, @user.reload.encrypted_password
    get projects_path
    assert_redirected_to new_user_session_path
  end

  test "email code signup includes name and only connects email code" do
    post users_email_code_path, params: { registration: "true", user: { email: "code-new@example.com", name: "Code Person" } }
    submit_code
    user = User.find_by!(email: "code-new@example.com")
    assert_equal "Code Person", user.name
    assert_equal ["email_code"], user.available_methods
    get edit_settings_user_path(user)
    assert_select "se-button[data-open-password-modal]:not([disabled])"
    assert_no_difference "ActionMailer::Base.deliveries.size" do
      post users_security_verification_path
    end
    patch authentication_methods_path, params: { user: { password: "Password123!", password_confirmation: "Password123!" } }
    assert_equal %w[email_code password], user.reload.available_methods.sort
    delete authentication_methods_path, params: { provider: "email_code" }
    assert_equal %w[email_code password], user.reload.available_methods.sort
    delete authentication_methods_path, params: { provider: "password" }
    assert_equal ["email_code"], user.reload.available_methods
  end

  test "removed email code cannot sign in or silently reconnect" do
    @user.auth_identities.where(provider: "email_code").destroy_all
    post users_email_code_path, params: { user: { email: @user.email } }
    assert_redirected_to users_email_code_path
    submit_code
    assert_redirected_to new_user_session_path
    assert_equal ["password"], @user.reload.available_methods
    get projects_path
    assert_redirected_to new_user_session_path
  end

  test "password recovery cannot add a missing password method" do
    @user.update!(encrypted_password: "", password_optional: true)
    assert_no_difference "ActionMailer::Base.deliveries.size" do
      post user_password_path, params: { user: { email: @user.email } }
    end
    assert_redirected_to new_user_session_path
    assert_not @user.reset_password("Password123!", "Password123!")
    assert_equal ["email_code"], @user.reload.available_methods
  end

  test "disconnecting password invalidates old recovery tokens" do
    token = @user.send_reset_password_instructions
    sign_in @user
    post users_security_verification_path
    submit_code
    delete authentication_methods_path, params: { provider: "password" }
    assert_nil @user.reload.reset_password_token
    sign_out @user
    patch user_password_path, params: { user: { reset_password_token: token, password: "Changed123!", password_confirmation: "Changed123!" } }
    assert_response :unprocessable_entity
    assert_equal ["email_code"], @user.reload.available_methods
  end

  test "connected passwords can be recovered and remain connected" do
    post user_password_path, params: { user: { email: @user.email } }
    assert_equal 1, ActionMailer::Base.deliveries.size
    token = @user.reload.send_reset_password_instructions
    patch user_password_path, params: { user: { reset_password_token: token, password: "Recovered123!", password_confirmation: "Recovered123!" } }
    assert_redirected_to new_user_session_path
    assert @user.reload.valid_password?("Recovered123!")
    assert_equal %w[email_code password], @user.available_methods.sort
  end

  test "first verified user is owner and subsequent users are guests" do
    AuthIdentity.delete_all
    User.delete_all
    first = User.register_verified!(email: "first@example.com", method: "email_code")
    second = User.register_verified!(email: "second@example.com", method: "email_code")
    assert first.owner?
    assert second.guest?
  end

  test "both registration and login offer segmented forms and keep validation on server" do
    [new_user_session_path, new_user_registration_path].each do |path|
      get path
      assert_response :success
      assert_select "se-segmented-control", count: 1
      assert_select "[data-method=password][hidden]", count: 1
      assert_select "form[novalidate]", count: 2
      assert_select "[required]", count: 0
    end
    assert_select "[data-method=email_code] se-input[name='user[name]']", count: 1
  end

  test "cooldown retries do not consume the hourly email allowance" do
    post users_email_code_path, params: { user: { email: @user.email } }
    6.times do
      post users_email_code_path, params: { user: { email: @user.email } }
      assert_response :too_many_requests
    end
    travel 61.seconds do
      post users_email_code_path, params: { user: { email: @user.email } }
      assert_redirected_to users_email_code_path
    end
    assert_equal 2, ActionMailer::Base.deliveries.size
  end

  test "auth forms follow enabled methods and signup never includes provider buttons" do
    %w[password email_code].each do |method|
      ENV["AUTH_METHODS"] = "#{method},google,github,discord"
      [new_user_session_path, new_user_registration_path].each do |path|
        get path
        assert_response :success
        assert_select "se-segmented-control", count: 0
        assert_select "[data-auth-form-target=panel]", count: 1
        assert_select "[data-method=#{method}]:not([hidden])", count: 1
        assert_select ".app-provider-form", count: path == new_user_session_path ? 3 : 0
        assert_select ".app-auth-brand se-layout-brand", count: path == new_user_session_path ? 1 : 0
      end
    end
    ENV["AUTH_METHODS"] = "google,github,discord"
    get new_user_session_path
    assert_response :success
    assert_select ".app-provider-form se-button[variant=primary][icon]", count: 3
    assert_select "se-segmented-control, [data-auth-form-target=panel], .app-auth-divider", count: 0
    assert_select "se-button[href=?]", new_user_registration_path, count: 0
    get new_user_registration_path
    assert_response :not_found
    post user_registration_path, params: { user: { email: "no-signup@example.com" } }
    assert_response :not_found
  end
end
