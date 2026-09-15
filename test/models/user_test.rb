require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "first account becomes owner" do
    AuthIdentity.delete_all
    User.delete_all

    user = User.create!(email: "first@example.com", password: "Password123!", password_confirmation: "Password123!")

    assert_predicate user, :owner?
  end
end
