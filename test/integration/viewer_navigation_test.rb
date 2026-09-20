require "test_helper"

class ViewerNavigationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @viewer = users(:one)
    @viewer.update!(email_verified_at: Time.current)
    assert @viewer.guest?
    assert_equal 0, @viewer.role_before_type_cast
    @admin = users(:two)
    @admin.update!(email_verified_at: Time.current)
    @public = Project.create!(name: "Shared public", visibility: "public")
    @private = Project.create!(name: "Private team")
    @sheet = @public.sheets.create!(name: "Shared sheet", visibility: "public")
    @hidden = @public.sheets.create!(name: "Private sheet")
    @private_sheet = @private.sheets.create!(name: "Hidden by project", visibility: "public")
    sign_in @viewer
  end

  test "viewer landing and personal settings retain the header with global navigation" do
    get projects_path
    assert_select "se-topbar se-profile"
    assert_select "se-empty-illustration[title][text]"
    assert_select "se-title[level=page]", text: "Projects"
    assert_select "se-card", count: 0
    assert_select "se-sidebar", count: 1
    assert_select "se-sidebar-toggle", count: 1
    get edit_settings_user_path(@viewer)
    assert_response :success
    assert_select "se-profile"
    assert_select "se-sidebar", count: 1
    assert_select "se-button[data-open-delete-modal]"
    get projects_path
    assert_select "se-workspace-card", count: 0
    assert_select "se-modal#project-create-modal", count: 0
    assert_no_difference "Project.count" do
      post projects_path, params: { project: { name: "Not allowed" } }
    end
    assert_response :forbidden
  end

  test "shared public links allow reading but not private data or mutations" do
    get project_sheets_path(@public)
    assert_response :success
    assert_select "se-sidebar", count: 1
    get project_sheets_path(@public)
    assert_select "se-project-card", count: 1
    assert_select "se-project-card[title='Shared sheet']"
    assert_select "se-button[data-open-modal=sheet-create-modal]", count: 0
    get translations_project_sheet_path(@public, @sheet)
    assert_response :success
    assert_select "se-sidebar", count: 1
    assert_select "se-sidebar-chapter", count: 1
    assert_select "se-sidebar-chapter[title=Project]:not([layout-mode])", count: 1
    assert_select "se-sidebar-chapter[title=Administration]", count: 0
    get translations_project_sheet_path(@public, @hidden)
    assert_response :not_found
    get translations_project_sheet_path(@private, @private_sheet)
    assert_response :not_found
    get members_project_path(@public)
    assert_response :not_found
    post project_sheets_path(@public), params: { sheet: { name: "Not allowed" } }
    assert_response :forbidden
    post project_project_invites_path(@public), params: { email: "someone@example.com" }
    assert_response :not_found
    @private.project_memberships.create!(user: @viewer, role: "viewer")
    get translations_project_sheet_path(@private, @private_sheet)
    assert_response :success
    get projects_path
    assert_select "se-workspace-card", count: 1
    assert_select "se-workspace-card[title='Private team']"
  end

  test "admins and owners have the all-projects directory" do
    get settings_projects_path
    assert_redirected_to projects_path
    sign_in @admin
    get settings_projects_path
    assert_response :success
    @admin.update!(role: :owner)
    get settings_projects_path
    assert_response :success
    assert_select "se-list-row", count: 2
    assert_select "se-workspace-card", count: 0
    assert_select "se-button[variant=link][href=?]", project_path(@private)
    assert_select "se-sidebar-chapter[title=Administration] se-sidebar-button[href=?]", settings_projects_path
  end

  test "banned tab excludes unverified accounts and replaces an empty table with illustration" do
    sign_in @admin
    unverified = User.create!(email: "unverified@example.com", password_optional: true)
    get settings_users_path(status: "banned")
    assert_select "header.app-heading se-segmented-control[value=banned][name=status]"
    assert_select "form[data-segmented-navigation][method=get]"
    assert_select "se-collection", count: 0
    assert_select "se-empty-illustration[variant=team-2][illustration-label=Banned][title='No banned users']"
    get settings_users_path
    assert_select "se-list-row se-profile[subtitle=?]", unverified.email, count: 1
    assert_select "se-badge[text=Unverified]"
    assert_select "se-badge[text=Verified]"
    @viewer.update!(banned_at: Time.current)
    get settings_users_path(status: "banned")
    assert_select "se-list-row", count: 1
    assert_select "se-list-row se-profile[subtitle=?]", unverified.email, count: 0
    assert_select "se-badge[text=Banned]", count: 0
  end
end
