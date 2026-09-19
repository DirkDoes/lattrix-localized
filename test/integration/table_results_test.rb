require "test_helper"

class TableResultsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner = users(:two)
    @owner.update!(role: :owner, email_verified_at: Time.current)
    sign_in @owner
    @workspace = Workspace.create!(name: "Pagination team")
    @workspace.workspace_memberships.create!(user: @owner, role: "owner")
    23.times do |index|
      user = User.create!(name: "Result person #{index.to_s.rjust(2, '0')}", email: "result-#{index}@example.com", password_optional: true)
      @workspace.workspace_memberships.create!(user: user, role: "viewer")
      Workspace.create!(name: "Result workspace #{index.to_s.rjust(2, '0')}")
    end
  end

  test "users search name and email with bounded pages and literal wildcard handling" do
    get settings_users_path(q: "RESULT PERSON", per_page: 100)
    assert_select "form[data-controller=table-search] se-input[type=search]:not([label])"
    assert_select "form[data-controller=table-search] se-button", count: 0
    assert_select "[data-table-results] se-pagination"
    assert_select "se-list-row", count: 20
    assert_select "se-pagination[page='1'][pages='2']"
    get settings_users_path(q: "result person", page: 2)
    assert_select "se-list-row", count: 3
    assert_select "se-pagination[data-pagination-url*='q=result']"
    get settings_users_path(q: "result-22@example.com")
    assert_select "se-list-row", count: 1
    get settings_users_path(q: "%")
    assert_select "se-list-row", count: 0
    assert_select "se-pagination", count: 0
    get settings_users_path(q: "' OR 1=1 --")
    assert_select "se-list-row", count: 0
    User.where("email LIKE ?", "result-%").update_all(banned_at: Time.current)
    get settings_users_path(status: "banned", q: "result", page: 2)
    assert_select "se-list-row", count: 3
    assert_select "se-pagination[data-pagination-url*='status=banned']"
    get settings_users_path(status: "active", q: "result")
    assert_select "se-list-row", count: 0
  end

  test "workspace directory and member search paginate in their authorized scopes" do
    get settings_workspaces_path(q: "result workspace", page: 2)
    assert_select "se-list-row", count: 3
    assert_select "se-pagination[pages='2']"
    get settings_workspaces_path(q: "result_workspace_22")
    assert_select "se-list-row", count: 1
    get members_workspace_path(@workspace, q: "result person")
    assert_select "se-list-row", count: 20
    assert_select "se-menu[data-members-menu]"
    get members_workspace_path(@workspace, q: "result person", page: 999999)
    assert_select "se-pagination[page='2'][pages='2']"
    assert_select "se-list-row", count: 3
    get members_workspace_path(@workspace, q: "result-22@example.com", page: -1)
    assert_select "se-list-row", count: 1
    assert_select "se-pagination[page='1'][pages='1']"
    other = Workspace.create!(name: "Unrelated")
    other.workspace_memberships.create!(user: @owner, role: "owner")
    get members_workspace_path(other, q: "result")
    assert_select "se-list-row", count: 0
    assert_select "se-pagination", count: 0
    users(:one).update!(email_verified_at: Time.current)
    sign_out @owner
    sign_in users(:one)
    get overview_path
    assert_response :success
    assert_equal "guest", controller.send(:current_user).role
    get members_workspace_path(@workspace, q: "result")
    assert_response :not_found
    get settings_workspaces_path(q: "result")
    assert_redirected_to overview_path
  end
end
