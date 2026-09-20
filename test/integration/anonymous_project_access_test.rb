require "test_helper"

class AnonymousProjectAccessTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @public = Project.create!(name: "Open team", visibility: "public")
    @private = Project.create!(name: "Private team")
    @sheet = @public.sheets.create!(name: "Open sheet", visibility: "public")
    @hidden = @public.sheets.create!(name: "Hidden sheet")
    @hidden_parent = @private.sheets.create!(name: "Public within private", visibility: "public")
  end

  test "anonymous project pages have login but no global sidebar and list public sheets only" do
    get project_sheets_path(@public)
    assert_response :success
    assert_select "se-sidebar", count: 0
    assert_select "se-sidebar-toggle", count: 0
    assert_select "se-button[href=?]", new_user_session_path
    assert_select "se-profile", count: 0
    get project_sheets_path(@public)
    assert_response :success
    assert_select "se-project-card[title='Open sheet']"
    assert_select "se-project-card[title='Hidden sheet']", count: 0
    assert_select "se-button[data-open-modal=sheet-create-modal]", count: 0
    assert_select "se-sidebar", count: 0
  end

  test "anonymous public sheets retain only sheet navigation" do
    [translations_project_sheet_path(@public, @sheet)].each do |path|
      get path
      assert_response :success
      assert_select "se-sidebar", count: 0
      assert_select "se-nav-tabs[label='Sheet navigation']"
      assert_select "se-sidebar-chapter[title=Project]", count: 0
      assert_select "se-sidebar-chapter[title=Administration]", count: 0
      assert_select "se-profile", count: 0
      assert_select "se-breadcrumbs", count: 0
    end
  end

  test "private links and nonpublic pages still require login" do
    [project_path(@private), project_sheets_path(@private),
     project_sheet_path(@private, @hidden_parent),
     project_sheet_path(@public, @hidden),
     translations_project_sheet_path(@public, @hidden),
     members_project_path(@public), settings_project_path(@public),
     projects_path, project_invites_path, projects_path].each do |path|
      get path
      assert_redirected_to new_user_session_path
    end
    assert_no_difference ["Project.count", "Sheet.count", "ProjectInvite.count"] do
      post project_sheets_path(@public), params: { sheet: { name: "Forbidden" } }
      assert_redirected_to new_user_session_path
      patch project_path(@public), params: { project: { name: "Forbidden" } }
      assert_redirected_to new_user_session_path
      post project_project_invites_path(@public), params: { email: "visitor@example.com" }
      assert_redirected_to new_user_session_path
    end
    assert_equal "Open team", @public.reload.name
  end

  test "signed in guests keep global navigation and administrators retain private access" do
    user = users(:one)
    user.update!(email_verified_at: Time.current, role: :guest)
    sign_in user
    get project_sheets_path(@public)
    assert_response :success
    assert_select "se-sidebar-chapter[title=Project]"
    get project_sheets_path(@private)
    assert_response :not_found
    @private.project_memberships.create!(user: user, role: "viewer")
    get project_sheets_path(@private)
    assert_response :success
    user.project_memberships.destroy_all
    %w[admin owner].each do |role|
      user.update!(role: role)
      get project_sheets_path(@private)
      assert_response :success
    end
  end

  test "banned signed-in accounts remain blocked even on public pages" do
    user = users(:one)
    user.update!(email_verified_at: Time.current, banned_at: Time.current)
    sign_in user
    get project_sheets_path(@public)
    assert_response :forbidden
  end
end
