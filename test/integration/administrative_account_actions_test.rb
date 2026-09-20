require "test_helper"

class AdministrativeAccountActionsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @actor = users(:two)
    @actor.update!(email_verified_at: Time.current, role: :owner)
    @target = users(:one)
    @target.update!(email_verified_at: Time.current, role: :guest)
    sign_in @actor
  end

  test "ban and restore from tables redirect to the same filtered list" do
    patch ban_settings_user_path(@target), params: { return_to: "users", status: "active", q: @target.name, page: "1" }
    assert_response :see_other
    assert_redirected_to settings_users_path(status: "active", q: @target.name, page: "1")
    follow_redirect!
    assert_select "[data-table-results] se-list-row", count: 0
    patch ban_settings_user_path(@target), params: { return_to: "users", status: "banned", q: @target.name, page: "1" }
    assert_redirected_to settings_users_path(status: "banned", q: @target.name, page: "1")
    follow_redirect!
    assert_select "[data-table-results] se-list-row", count: 0
    assert_nil @target.reload.banned_at
  end

  test "deleting a nonowner transfers sole ownership and preserves shared projects" do
    sole = Project.create!(name: "Sole")
    sole.project_memberships.create!(user: @target, role: "owner")
    sheet = sole.sheets.create!(name: "Keep sheet")
    joined = Project.create!(name: "Already joined")
    joined.project_memberships.create!(user: @target, role: "owner")
    joined.project_memberships.create!(user: @actor, role: "viewer")
    shared = Project.create!(name: "Shared")
    shared.project_memberships.create!(user: @target, role: "owner")
    remaining = User.register_verified!(email: "remaining@example.com")
    shared.project_memberships.create!(user: remaining, role: "owner")
    invite = sole.project_invites.create!(email: "future@example.com", invited_by: @target)
    delete settings_user_path(@target)
    assert_redirected_to settings_users_path
    assert_not User.exists?(@target.id)
    assert_equal "owner", sole.project_memberships.find_by!(user: @actor).role
    assert_equal "owner", joined.project_memberships.find_by!(user: @actor).role
    assert_equal [remaining.id], shared.project_memberships.pluck(:user_id)
    assert Sheet.exists?(sheet.id)
    assert_nil invite.reload.invited_by_id
    assert_equal 1, sole.project_memberships.count
    assert_equal 1, joined.project_memberships.count
  end

  test "even another owner cannot delete an owner before demotion" do
    @target.update!(role: :owner)
    assert_no_difference "User.count" do
      delete settings_user_path(@target)
    end
    assert_not @target.destroy
    assert User.exists?(@target.id)
    patch settings_user_path(@target), params: { user: { role: "guest" } }
    assert @target.reload.guest?
    assert_difference "User.count", -1 do
      delete settings_user_path(@target)
    end
  end

  test "profiles are passive and email is always underneath the name" do
    get settings_users_path
    assert_select "se-list-row se-profile[name=?][subtitle=?]:not([clickable]):not([options])", @target.name, @target.email
    assert_select "form[data-controller=table-action] input[name=return_to][value=users]"
  end
end
