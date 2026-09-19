require "test_helper"

class AnonymousWorkspaceAccessTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @public = Workspace.create!(name: "Open team", visibility: "public")
    @private = Workspace.create!(name: "Private team")
    @project = @public.projects.create!(name: "Open project", visibility: "public")
    @hidden = @public.projects.create!(name: "Hidden project")
    @hidden_parent = @private.projects.create!(name: "Public within private", visibility: "public")
  end

  test "anonymous workspace pages have login but no global sidebar and list public projects only" do
    get workspace_path(@public)
    assert_response :success
    assert_select "se-sidebar", count: 0
    assert_select "se-sidebar-toggle", count: 0
    assert_select "se-button[href=?]", new_user_session_path
    assert_select "se-profile", count: 0
    get workspace_projects_path(@public)
    assert_response :success
    assert_select "se-project-card[title='Open project']"
    assert_select "se-project-card[title='Hidden project']", count: 0
    assert_select "se-button[data-open-modal=project-create-modal]", count: 0
    assert_select "se-sidebar", count: 0
  end

  test "anonymous public projects retain only project navigation" do
    [workspace_project_path(@public, @project), translations_workspace_project_path(@public, @project)].each do |path|
      get path
      assert_response :success
      assert_select "se-sidebar", count: 1
      assert_select "se-sidebar-button[label=Translations]"
      assert_select "se-sidebar-chapter[title=Workspace]", count: 0
      assert_select "se-sidebar-chapter[title=Administration]", count: 0
      assert_select "se-profile", count: 0
      assert_select "se-breadcrumbs[variant=header]"
    end
  end

  test "private links and nonpublic pages still require login" do
    [workspace_path(@private), workspace_projects_path(@private),
     workspace_project_path(@private, @hidden_parent),
     workspace_project_path(@public, @hidden),
     translations_workspace_project_path(@public, @hidden),
     members_workspace_path(@public), settings_workspace_path(@public),
     workspaces_path, workspace_invites_path, overview_path].each do |path|
      get path
      assert_redirected_to new_user_session_path
    end
    assert_no_difference ["Workspace.count", "Project.count", "WorkspaceInvite.count"] do
      post workspace_projects_path(@public), params: { project: { name: "Forbidden" } }
      assert_redirected_to new_user_session_path
      patch workspace_path(@public), params: { workspace: { name: "Forbidden" } }
      assert_redirected_to new_user_session_path
      post workspace_workspace_invites_path(@public), params: { email: "visitor@example.com" }
      assert_redirected_to new_user_session_path
    end
    assert_equal "Open team", @public.reload.name
  end

  test "signed in guests keep global navigation and administrators retain private access" do
    user = users(:one)
    user.update!(email_verified_at: Time.current, role: :guest)
    sign_in user
    get workspace_path(@public)
    assert_response :success
    assert_select "se-sidebar-chapter[title=Workspace]"
    get workspace_path(@private)
    assert_response :not_found
    @private.workspace_memberships.create!(user: user, role: "viewer")
    get workspace_path(@private)
    assert_response :success
    user.workspace_memberships.destroy_all
    %w[admin owner].each do |role|
      user.update!(role: role)
      get workspace_path(@private)
      assert_response :success
    end
  end

  test "banned signed-in accounts remain blocked even on public pages" do
    user = users(:one)
    user.update!(email_verified_at: Time.current, banned_at: Time.current)
    sign_in user
    get workspace_path(@public)
    assert_response :forbidden
  end
end
