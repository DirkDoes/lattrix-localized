require "test_helper"

class GlobalRolesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current, role: :member)
    sign_in @user
  end

  test "member project creation is capped at three owned projects" do
    other = Project.create!(name: "Invited team")
    other.project_memberships.create!(user: @user, role: "admin")
    get projects_path
    assert_select "header se-button[text='Create new project']"
    3.times do |index|
      assert_difference "Project.count" do
        post projects_path, params: { project: { name: "My team #{index}" } }
      end
      assert_response :redirect
    end
    assert_equal 3, @user.project_memberships.where(role: "owner").count
    assert_no_difference "Project.count" do
      post projects_path, params: { project: { name: "Fourth" } }
    end
    assert_response :unprocessable_entity
    assert_select "se-text[role=alert]", text: /three projects/
    get projects_path
    assert_select "se-button[data-open-modal=project-create-modal]", count: 0
    assert_select "se-workspace-card", count: 4
    get settings_users_path
    assert_redirected_to projects_path
    get settings_projects_path
    assert_redirected_to projects_path
  end

  test "empty states distinguish guests and members and invitations live in the sidebar" do
    get projects_path
    assert_select "header se-button[data-open-modal=project-create-modal]", count: 0
    assert_select "se-empty-illustration se-button[text='Create new project']"
    assert_select "se-sidebar-button[label=Invitations][href=?]", project_invites_path
    assert_select "header se-button[href=?]", project_invites_path, count: 0
    assert_select "se-sidebar-chapter[title=Administration]", count: 0
    assert_select "se-sidebar[data-navigation-user=?]", @user.id
    assert_select "se-sidebar-group#projects-navigation", count: 0
    assert_select "se-sidebar-button[label=Projects]"
    @user.update!(role: :guest)
    get projects_path
    assert_select "se-empty-illustration[subtitle*='invite you']"
    assert_select "se-modal#project-create-modal", count: 0
    assert_no_difference "Project.count" do
      post projects_path, params: { project: { name: "Forbidden" } }
    end
    assert_response :forbidden
  end

  test "admins and owners have no project cap and downgrade keeps existing projects" do
    @user.update!(role: :admin)
    4.times do |index|
      post projects_path, params: { project: { name: "Admin team #{index}" } }
      assert_response :redirect
    end
    @user.update!(role: :owner)
    post projects_path, params: { project: { name: "Owner team" } }
    assert_response :redirect
    users(:two).update!(role: :owner, email_verified_at: Time.current)
    @user.update!(role: :member)
    assert_equal 5, @user.projects.count
    get projects_path
    assert_select "se-workspace-card", count: 5
    assert_no_difference "Project.count" do
      post projects_path, params: { project: { name: "Too many" } }
    end
    assert_response :unprocessable_entity
    assert_equal 5, @user.projects.count
  end

  test "all projects have a 90 sheet cap even for global owners" do
    project = Project.create!(name: "Sheet limit")
    project.project_memberships.create!(user: @user, role: "owner")
    89.times { |index| project.sheets.create!(name: "Sheet #{index}") }
    assert_difference "Sheet.count" do
      post project_sheets_path(project), params: { sheet: { name: "Ninetieth" } }
    end
    assert_response :redirect
    %w[member admin owner].each do |role|
      @user.update!(role: role)
      assert_no_difference "Sheet.count" do
        post project_sheets_path(project), params: { sheet: { name: "Ninety first" } }
      end
      assert_response :unprocessable_entity
      assert_select "se-text[role=alert]", text: /90 sheets/
    end
    assert project.sheets.first.update(name: "Existing sheet remains editable")
  end

  test "global admins manage unrelated private projects" do
    @user.update!(role: :admin)
    get projects_path
    assert_select "se-sidebar-chapter#administration-navigation[collapsible][collapsed]"
    project = Project.create!(name: "Private unrelated")
    get settings_project_path(project)
    assert_response :success
    patch project_path(project), params: { project: { name: "Updated" } }
    assert_redirected_to settings_project_path(project)
    assert_equal "Updated", project.reload.name
    post project_sheets_path(project), params: { sheet: { name: "Admin sheet" } }
    assert_response :redirect
    get members_project_path(project)
    assert_response :success
    assert_select "se-menu[data-members-menu]"
    post project_project_invites_path(project), params: { email: "new@example.com" }
    assert_redirected_to members_project_path(project)
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
