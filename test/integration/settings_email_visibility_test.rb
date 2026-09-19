require "test_helper"

class SettingsEmailVisibilityTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "email is displayed on authorized settings pages but not the header" do
    person = users(:one)
    person.update!(email_verified_at: Time.current)
    sign_in person
    get edit_settings_user_path(person)
    assert_response :success
    assert_select "se-card se-profile[subtitle=?]", person.email
    assert_select "se-topbar se-profile[subtitle]", count: 0
    other = users(:two)
    other.update!(email_verified_at: Time.current, role: :admin)
    sign_in other
    get edit_settings_user_path(person)
    assert_response :success
    assert_select "se-card se-profile[subtitle=?]", person.email
    other.update!(role: :owner)
    get edit_settings_user_path(person)
    assert_response :success
    assert_select "se-card se-profile[subtitle=?]", person.email
    sign_in person
    get edit_settings_user_path(other)
    assert_response :redirect
    assert_not_includes response.body, other.email
  end
end
