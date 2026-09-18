require "test_helper"

class ProjectsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "sidebar collapse preference survives navigation" do
    owner = users(:one)
    owner.update!(email_verified_at: Time.current, role: :admin)
    sign_in owner
    cookies[:sidebar_collapsed] = "true"
    get workspaces_path
    assert_select "se-sidebar[collapsed][collapsible]"
    get overview_path
    assert_select "se-sidebar[collapsed][collapsible]"
    cookies[:sidebar_collapsed] = "false"
    get workspaces_path
    assert_select "se-sidebar[collapsible]:not([collapsed])"
  end

  test "projects stay scoped, creation is authorized, and navigation follows the scope" do
    owner = users(:one)
    owner.update!(email_verified_at: Time.current, role: :admin)
    workspace = Workspace.create!(name: "Team", visibility: "private")
    membership = workspace.workspace_memberships.create!(user: owner, role: "owner")
    sign_in owner
    get workspace_projects_path(workspace)
    assert_select "header se-button[data-open-modal=project-create-modal]", count: 0
    assert_select "se-empty-illustration[variant=folders][title='No projects yet'] se-button[data-open-modal=project-create-modal]", count: 1
    membership.update!(role: "viewer")
    get workspace_projects_path(workspace)
    assert_select "se-empty-illustration[variant=folders]"
    assert_select "se-button[data-open-modal=project-create-modal]", count: 0
    membership.update!(role: "owner")
    post workspace_projects_path(workspace), params: { project: { name: "Website", visibility: "public" } }
    project = workspace.projects.sole
    assert_redirected_to workspace_project_path(workspace, project)
    assert_equal "private", project.effective_visibility
    get workspace_project_path(workspace, project)
    assert_select "se-sidebar[collapsible]:not([variant])", count: 1
    assert_select "se-sidebar[layout-mode=responsive] se-sidebar-button[label=Translations]"
    assert_select "se-sidebar se-sidebar-chapter[layout-mode=mobile-only] se-sidebar-group[variant=page]"
    assert_select "se-topbar se-profile"
    assert_select "se-topbar se-layout-brand"
    assert_select "se-topbar se-breadcrumbs[variant=header]" do |elements|
      trail = JSON.parse(elements.first["options"])
      assert_equal [workspace_path(workspace), workspace_project_path(workspace, project)], trail.map { |item| item["href"] }
    end
    assert_select "se-topbar se-breadcrumbs[layout-mode=desktop-only]"
    assert_select "se-sidebar > header[layout-mode=mobile-only] se-breadcrumbs[variant=header]"
    assert_select "se-sidebar-chapter + se-sidebar-chapter[title=Workspace]"
    assert_select "dialog#app-navigation", count: 0
    get translations_workspace_project_path(workspace, project)
    assert_response :success
    get workspace_projects_path(workspace)
    assert_select "se-nav-tabs[value=projects]"
    assert_select "se-project-card[title=Website]"
    assert_select "header se-button[data-open-modal=project-create-modal]", count: 1
    assert_select "se-empty-illustration", count: 0
    assert_select "se-sidebar[collapsible]:not([variant])", count: 1
    assert_select "se-breadcrumbs", count: 0
    assert_select ".app-mobile-workspaces", count: 0
    get workspaces_path
    assert_select "se-sidebar-group[variant=page][active]"
    assert_no_difference "Project.count" do
      post workspace_projects_path(workspace), params: { project: { name: "", visibility: "bad" } }
    end
    assert_response :unprocessable_entity
    assert_select "se-modal#project-create-modal[open]"
    membership.update!(role: "viewer")
    post workspace_projects_path(workspace), params: { project: { name: "Forbidden" } }
    assert_response :forbidden
    other = Workspace.create!(name: "Other")
    other.workspace_memberships.create!(user: owner, role: "owner")
    get workspace_project_path(other, project)
    assert_response :not_found
    membership.destroy!
    get workspace_projects_path(workspace)
    assert_response :not_found
  end
end
