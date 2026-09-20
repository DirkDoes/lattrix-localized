require "test_helper"

class ProjectPermissionsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner = users(:one)
    @owner.update!(email_verified_at: Time.current, role: :member)
    @other = users(:two)
    @other.update!(email_verified_at: Time.current, role: :guest)
    @project = Project.create!(name: "Team")
    @ownership = @project.project_memberships.create!(user: @owner, role: "owner")
    sign_in @owner
  end

  test "public access never creates membership or lists unrelated projects" do
    @project.update!(visibility: "public")
    sign_in @other
    get project_sheets_path(@project)
    assert_response :success
    get projects_path
    assert_select "se-workspace-card", count: 0
    assert_select "se-sidebar-group#projects-navigation", count: 0
    assert_select "se-sidebar-button[label=Projects]"
    assert_empty @other.project_memberships
    @project.update!(visibility: "private")
    get project_sheets_path(@project)
    assert_response :not_found
    membership = @project.project_memberships.create!(user: @other, role: "viewer")
    %w[viewer translator admin owner].each do |role|
      membership.update!(role: role)
      get project_sheets_path(@project)
      assert_response :success
      get projects_path
      assert_select "se-workspace-card[title=Team]"
      assert_select "se-sidebar-group#projects-navigation"
    end
  end

  test "translators see member names but cannot retrieve emails through display or search" do
    membership = @project.project_memberships.create!(user: @other, role: "viewer")
    sign_in @other
    get members_project_path(@project)
    assert_response :not_found
    membership.update!(role: "translator")
    sign_in @other
    get members_project_path(@project)
    assert_response :success
    assert_includes response.body, @owner.name
    assert_not_includes response.body, @owner.email
    assert_not_includes response.body, @other.email
    assert_select "se-button[text=Edit]", count: 0
    get members_project_path(@project), params: { q: @owner.email }
    assert_select "se-list-row", count: 0
    get project_invites_path
    assert_not_includes response.body, @other.email
    membership.update!(role: "admin")
    get members_project_path(@project)
    assert_includes response.body, @owner.email
  end

  test "admins manage lower roles but cannot edit or remove elevated memberships" do
    admin = @project.project_memberships.create!(user: @other, role: "admin")
    target = User.register_verified!(email: "target@example.com")
    membership = @project.project_memberships.create!(user: target, role: "viewer")
    sign_in @other
    patch project_project_membership_path(@project, membership), params: { project_membership: { role: "translator" } }
    assert_response :redirect
    assert_equal "translator", membership.reload.role
    %w[admin owner].each do |role|
      patch project_project_membership_path(@project, membership), params: { project_membership: { role: role } }
      assert_response :forbidden
    end
    [@ownership, admin].each do |protected_membership|
      patch project_project_membership_path(@project, protected_membership), params: { project_membership: { role: "viewer" } }
      assert_response :forbidden
      delete project_project_membership_path(@project, protected_membership)
      assert_response :forbidden
      assert ProjectMembership.exists?(protected_membership.id)
    end
    delete project_path(@project), params: { confirmation: "DELETE PROJECT" }
    assert_response :forbidden
    delete project_project_membership_path(@project, membership)
    assert_response :redirect
    assert_not ProjectMembership.exists?(membership.id)
  end

  test "owner can elevate joined users but cannot remove or demote the last owner" do
    membership = @project.project_memberships.create!(user: @other, role: "viewer")
    %w[admin owner].each do |role|
      patch project_project_membership_path(@project, membership), params: { project_membership: { role: role } }
      assert_response :redirect
      assert_equal role, membership.reload.role
    end
    delete project_project_membership_path(@project, membership)
    assert_response :forbidden
    assert ProjectMembership.exists?(membership.id)
    patch project_project_membership_path(@project, membership), params: { project_membership: { role: "translator" } }
    assert_response :redirect
    patch project_project_membership_path(@project, @ownership), params: { project_membership: { role: "admin" } }
    assert_response :forbidden
    assert_equal "owner", @ownership.reload.role
    delete project_project_membership_path(@project, @ownership)
    assert_response :forbidden
    assert ProjectMembership.exists?(@ownership.id)
    unrelated = Project.create!(name: "Other")
    unrelated_membership = unrelated.project_memberships.create!(user: @other, role: "viewer")
    patch project_project_membership_path(@project, unrelated_membership), params: { project_membership: { role: "admin" } }
    assert_response :not_found
  end

  test "invites persist only low roles and accepting cannot override the offered role" do
    %w[admin owner nonsense].each do |role|
      assert_no_difference "ProjectInvite.count" do
        post project_project_invites_path(@project), params: { email: @other.email, role: role }
      end
      assert_response :unprocessable_entity
    end
    post project_project_invites_path(@project), params: { email: @other.email, role: "translator" }
    assert_response :redirect
    invite = @project.project_invites.sole
    assert_equal "translator", invite.role
    post project_project_invites_path(@project), params: { email: @other.email, role: "viewer" }
    assert_equal "translator", invite.reload.role
    sign_in @other
    patch project_invite_path(invite), params: { decision: "accept", role: "owner" }
    assert_response :redirect
    assert_equal "translator", @project.project_memberships.find_by!(user: @other).role
  end

  test "project deletion requires exact confirmation and removes dependent data" do
    sheet = @project.sheets.create!(name: "Website")
    invite = @project.project_invites.create!(email: @other.email)
    delete project_path(@project), params: { confirmation: "delete project" }
    assert_response :unprocessable_entity
    assert Project.exists?(@project.id)
    assert_select "se-modal#project-delete-confirmation[open]"
    delete project_path(@project), params: { confirmation: "DELETE PROJECT" }
    assert_redirected_to projects_path
    assert_not Project.exists?(@project.id)
    assert_not Sheet.exists?(sheet.id)
    assert_not ProjectInvite.exists?(invite.id)
    assert_not ProjectMembership.exists?(@ownership.id)
  end

  test "global owner override does not give global admins sensitive project powers" do
    @other.update!(role: :admin)
    sign_in @other
    patch project_path(@project), params: { project: { visibility: "public" }, confirm_visibility: "1" }
    assert_response :forbidden
    @other.update!(role: :owner)
    patch project_path(@project), params: { project: { visibility: "public" }, confirm_visibility: "1" }
    assert_response :redirect
    assert_equal "public", @project.reload.visibility
  end

  test "deleting an account cannot strand its project without an owner" do
    assert_not @owner.destroy
    assert User.exists?(@owner.id)
    assert ProjectMembership.exists?(@ownership.id)
  end
end
