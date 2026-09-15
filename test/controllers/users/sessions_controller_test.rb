require "test_helper"

class Users::SessionsControllerTest < ActionDispatch::IntegrationTest
  test "empty login reaches backend validation" do
    post user_session_path, params: { user: { email: "", password: "" } }

    assert_response :unprocessable_entity
    assert_select "form[novalidate]"
    assert_select "se-input[error=?]", "Email can't be blank."
  end
end
