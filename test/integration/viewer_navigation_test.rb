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
    @public = Workspace.create!(name: "Shared public", visibility: "public")
    @private = Workspace.create!(name: "Private team")
    @project = @public.projects.create!(name: "Shared project", visibility: "public")
    @hidden = @public.projects.create!(name: "Private project")
    @private_project = @private.projects.create!(name: "Hidden by workspace", visibility: "public")
    sign_in @viewer
  end

  test "viewer landing and personal settings retain the header without global navigation" do
    get overview_path
    assert_select "se-topbar se-profile"
    assert_select "se-empty-illustration[variant=translation-2][title][text]"
    assert_select "se-title[level=page]", text: "Welcome back, #{@viewer.name}"
    assert_select "se-card", count: 0
    assert_select "se-sidebar", count: 0
    assert_select "se-sidebar-toggle", count: 0
    get edit_settings_user_path(@viewer)
    assert_response :success
    assert_select "se-profile"
    assert_select "se-sidebar", count: 0
    assert_select "se-button[data-open-delete-modal]"
    get workspaces_path
    assert_select "se-workspace-card", count: 0
    assert_select "se-modal#workspace-create-modal", count: 0
    assert_no_difference "Workspace.count" do
      post workspaces_path, params: { workspace: { name: "Not allowed" } }
    end
    assert_response :forbidden
  end

  test "shared public links allow reading but not private data or mutations" do
    get workspace_path(@public)
    assert_response :success
    assert_select "se-sidebar", count: 0
    get workspace_projects_path(@public)
    assert_select "se-project-card", count: 1
    assert_select "se-project-card[title='Shared project']"
    assert_select "se-button[data-open-modal=project-create-modal]", count: 0
    get translations_workspace_project_path(@public, @project)
    assert_response :success
    assert_select "se-sidebar", count: 1
    assert_select "se-sidebar-chapter", count: 1
    assert_select "se-sidebar-chapter[title=Workspace]", count: 0
    assert_select "se-sidebar-chapter[title=Administration]", count: 0
    get workspace_project_path(@public, @hidden)
    assert_response :not_found
    get workspace_project_path(@private, @private_project)
    assert_response :not_found
    get members_workspace_path(@public)
    assert_response :not_found
    post workspace_projects_path(@public), params: { project: { name: "Not allowed" } }
    assert_response :forbidden
    post workspace_workspace_invites_path(@public), params: { email: "someone@example.com" }
    assert_response :not_found
    @private.workspace_memberships.create!(user: @viewer, role: "viewer")
    get workspace_project_path(@private, @private_project)
    assert_response :success
    get workspaces_path
    assert_select "se-workspace-card", count: 1
    assert_select "se-workspace-card[title='Private team']"
  end

  test "only owners have the all-workspaces directory" do
    get settings_workspaces_path
    assert_redirected_to settings_users_path
    sign_in @admin
    get settings_workspaces_path
    assert_redirected_to settings_users_path
    @admin.update!(role: :owner)
    get settings_workspaces_path
    assert_response :success
    assert_select "se-list-row", count: 2
    assert_select "se-workspace-card", count: 0
    assert_select "se-button[variant=link][href=?]", workspace_path(@private)
    assert_select "se-sidebar-chapter[title=Administration] se-sidebar-button[href=?]", settings_workspaces_path
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
    assert_select "se-list-row", text: /#{Regexp.escape(unverified.email)}/, count: 1
    assert_select "se-badge[text=Unverified]"
    assert_select "se-badge[text=Verified]"
    @viewer.update!(banned_at: Time.current)
    get settings_users_path(status: "banned")
    assert_select "se-list-row", count: 1
    assert_select "se-list-row", text: /#{Regexp.escape(unverified.email)}/, count: 0
    assert_select "se-badge[text=Banned]", count: 0
  end
end
