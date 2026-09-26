require "test_helper"

class AccountDeletionTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    AuthRateLimit.delete_all
    ActionMailer::Base.deliveries.clear
    sign_in @user
  end

  def confirm_identity
    post users_security_verification_path, params: { next: "delete" }
    patch users_email_code_path, params: { code: email_code_from_last_delivery }
    assert_redirected_to edit_settings_user_path(@user, account_action: "delete")
  end

  test "deletion requires recent proof and exact typed confirmation and removes only self" do
    assert_no_difference "User.count" do
      delete user_registration_path, params: { confirmation: "DELETE MY ACCOUNT" }
    end
    confirm_identity
    follow_redirect!
    assert_select "se-modal#delete-account-confirmation[open]"
    assert_no_difference "User.count" do
      delete user_registration_path, params: { confirmation: "delete my account" }
    end
    challenge, = EmailChallenge.issue!(email: @user.email, purpose: "login")
    assert_difference "User.count", -1 do
      delete user_registration_path, params: { id: users(:two).id, confirmation: "DELETE MY ACCOUNT" }
    end
    assert_redirected_to new_user_session_path
    assert User.exists?(users(:two).id)
    assert_not AuthIdentity.exists?(user_id: @user.id)
    assert_not EmailChallenge.exists?(challenge.id)
    get projects_path
    assert_redirected_to new_user_session_path
  end

  test "expired proof cannot delete an account" do
    confirm_identity
    travel 11.minutes do
      assert_no_difference "User.count" do
        delete user_registration_path, params: { confirmation: "DELETE MY ACCOUNT" }
      end
    end
  end

  test "last owner cannot delete their account" do
    @user.update!(role: :owner)
    confirm_identity
    assert_no_difference "User.count" do
      delete user_registration_path, params: { confirmation: "DELETE MY ACCOUNT" }
    end
    assert_redirected_to edit_settings_user_path(@user)
    assert_match "Demote this owner", flash[:alert]
  end
end
