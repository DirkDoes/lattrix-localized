require "test_helper"

class GlobalRolesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current, role: :member)
    sign_in @user
  end

  test "member workspace creation is capped at three owned workspaces" do
    other = Workspace.create!(name: "Invited team")
    other.workspace_memberships.create!(user: @user, role: "admin")
    get workspaces_path
    assert_select "header se-button[text='Create new workspace']"
    3.times do |index|
      assert_difference "Workspace.count" do
        post workspaces_path, params: { workspace: { name: "My team #{index}" } }
      end
      assert_response :redirect
    end
    assert_equal 3, @user.workspace_memberships.where(role: "owner").count
    assert_no_difference "Workspace.count" do
      post workspaces_path, params: { workspace: { name: "Fourth" } }
    end
    assert_response :unprocessable_entity
    assert_select "se-text[role=alert]", text: /three workspaces/
    get workspaces_path
    assert_select "se-button[data-open-modal=workspace-create-modal]", count: 0
    assert_select "se-workspace-card", count: 4
    get settings_users_path
    assert_redirected_to overview_path
    get settings_workspaces_path
    assert_redirected_to overview_path
  end

  test "empty states distinguish guests and members and invitations live in the sidebar" do
    get workspaces_path
    assert_select "header se-button[data-open-modal=workspace-create-modal]", count: 0
    assert_select "se-empty-illustration se-button[text='Create new workspace']"
    assert_select "se-sidebar-button[label=Invitations][href=?]", workspace_invites_path
    assert_select "header se-button[href=?]", workspace_invites_path, count: 0
    assert_select "se-sidebar-chapter[title=Administration]", count: 0
    assert_select "se-sidebar[data-navigation-user=?]", @user.id
    assert_select "se-sidebar-group#workspaces-navigation", count: 0
    assert_select "se-sidebar-button[label=Workspaces]"
    @user.update!(role: :guest)
    get workspaces_path
    assert_select "se-empty-illustration[text*='invite you']"
    assert_select "se-modal#workspace-create-modal", count: 0
    assert_no_difference "Workspace.count" do
      post workspaces_path, params: { workspace: { name: "Forbidden" } }
    end
    assert_response :forbidden
  end

  test "admins and owners have no workspace cap and downgrade keeps existing workspaces" do
    @user.update!(role: :admin)
    4.times do |index|
      post workspaces_path, params: { workspace: { name: "Admin team #{index}" } }
      assert_response :redirect
    end
    @user.update!(role: :owner)
    post workspaces_path, params: { workspace: { name: "Owner team" } }
    assert_response :redirect
    users(:two).update!(role: :owner, email_verified_at: Time.current)
    @user.update!(role: :member)
    assert_equal 5, @user.workspaces.count
    get workspaces_path
    assert_select "se-workspace-card", count: 5
    assert_no_difference "Workspace.count" do
      post workspaces_path, params: { workspace: { name: "Too many" } }
    end
    assert_response :unprocessable_entity
    assert_equal 5, @user.workspaces.count
  end

  test "all workspaces have a twelve project cap even for global owners" do
    workspace = Workspace.create!(name: "Project limit")
    workspace.workspace_memberships.create!(user: @user, role: "owner")
    11.times { |index| workspace.projects.create!(name: "Project #{index}") }
    assert_difference "Project.count" do
      post workspace_projects_path(workspace), params: { project: { name: "Twelfth" } }
    end
    assert_response :redirect
    %w[member admin owner].each do |role|
      @user.update!(role: role)
      assert_no_difference "Project.count" do
        post workspace_projects_path(workspace), params: { project: { name: "Thirteenth" } }
      end
      assert_response :unprocessable_entity
      assert_select "se-text[role=alert]", text: /12 projects/
    end
    assert workspace.projects.first.update(name: "Existing project remains editable")
  end

  test "global admins manage unrelated private workspaces" do
    @user.update!(role: :admin)
    get overview_path
    assert_select "se-sidebar-chapter#administration-navigation[collapsible][collapsed]"
    workspace = Workspace.create!(name: "Private unrelated")
    get settings_workspace_path(workspace)
    assert_response :success
    patch workspace_path(workspace), params: { workspace: { name: "Updated" } }
    assert_redirected_to settings_workspace_path(workspace)
    assert_equal "Updated", workspace.reload.name
    post workspace_projects_path(workspace), params: { project: { name: "Admin project" } }
    assert_response :redirect
    get members_workspace_path(workspace)
    assert_response :success
    assert_select "se-menu[data-members-menu]"
    post workspace_workspace_invites_path(workspace), params: { email: "new@example.com" }
    assert_redirected_to members_workspace_path(workspace)
  end

  test "admins can manage nonowners but never modify owners or delete accounts" do
    @user.update!(role: :admin)
    target = users(:two)
    target.update!(role: :owner, email_verified_at: Time.current)
    patch settings_user_path(target), params: { user: { name: "Forbidden", role: "member" } }
    assert_redirected_to settings_users_path
    patch ban_settings_user_path(target)
    assert_redirected_to settings_users_path
    assert_nil target.reload.banned_at
    assert target.owner?
    assert_equal "Two User", target.name
    assert_no_difference "User.count" do
      delete settings_user_path(target)
    end
    assert_redirected_to settings_users_path
    target = User.create!(name: "Member", email: "member@example.com", role: :member, password_optional: true)
    get edit_settings_user_path(target)
    assert_select "se-button[text='Delete user']", count: 0
    patch settings_user_path(target), params: { user: { role: "admin", name: "Updated" } }
    assert_redirected_to settings_users_path
    assert target.reload.admin?
    assert_equal "Updated", target.name
    patch ban_settings_user_path(target)
    assert_redirected_to edit_settings_user_path(target)
    assert target.reload.banned_at
    assert_no_difference "User.count" do
      delete settings_user_path(target)
    end
    assert_redirected_to settings_users_path
  end
end
