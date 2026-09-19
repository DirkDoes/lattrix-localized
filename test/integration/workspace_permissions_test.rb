require "test_helper"

class WorkspacePermissionsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner = users(:one)
    @owner.update!(email_verified_at: Time.current, role: :member)
    @other = users(:two)
    @other.update!(email_verified_at: Time.current, role: :guest)
    @workspace = Workspace.create!(name: "Team")
    @ownership = @workspace.workspace_memberships.create!(user: @owner, role: "owner")
    sign_in @owner
  end

  test "public access never creates membership or lists unrelated workspaces" do
    @workspace.update!(visibility: "public")
    sign_in @other
    get workspace_path(@workspace)
    assert_response :success
    get workspaces_path
    assert_select "se-workspace-card", count: 0
    assert_select "se-sidebar-group#workspaces-navigation", count: 0
    assert_select "se-sidebar-button[label=Workspaces]"
    assert_empty @other.workspace_memberships
    @workspace.update!(visibility: "private")
    get workspace_path(@workspace)
    assert_response :not_found
    membership = @workspace.workspace_memberships.create!(user: @other, role: "viewer")
    %w[viewer translator admin owner].each do |role|
      membership.update!(role: role)
      get workspace_path(@workspace)
      assert_response :success
      get workspaces_path
      assert_select "se-workspace-card[title=Team]"
      assert_select "se-sidebar-group#workspaces-navigation"
    end
  end

  test "translators see member names but cannot retrieve emails through display or search" do
    membership = @workspace.workspace_memberships.create!(user: @other, role: "viewer")
    sign_in @other
    get members_workspace_path(@workspace)
    assert_response :not_found
    membership.update!(role: "translator")
    sign_in @other
    get members_workspace_path(@workspace)
    assert_response :success
    assert_includes response.body, @owner.name
    assert_not_includes response.body, @owner.email
    assert_not_includes response.body, @other.email
    assert_select "se-button[text=Edit]", count: 0
    get members_workspace_path(@workspace), params: { q: @owner.email }
    assert_select "se-list-row", count: 0
    get workspace_invites_path
    assert_not_includes response.body, @other.email
    membership.update!(role: "admin")
    get members_workspace_path(@workspace)
    assert_includes response.body, @owner.email
  end

  test "admins manage lower roles but cannot edit or remove elevated memberships" do
    admin = @workspace.workspace_memberships.create!(user: @other, role: "admin")
    target = User.register_verified!(email: "target@example.com")
    membership = @workspace.workspace_memberships.create!(user: target, role: "viewer")
    sign_in @other
    patch workspace_workspace_membership_path(@workspace, membership), params: { workspace_membership: { role: "translator" } }
    assert_response :redirect
    assert_equal "translator", membership.reload.role
    %w[admin owner].each do |role|
      patch workspace_workspace_membership_path(@workspace, membership), params: { workspace_membership: { role: role } }
      assert_response :forbidden
    end
    [@ownership, admin].each do |protected_membership|
      patch workspace_workspace_membership_path(@workspace, protected_membership), params: { workspace_membership: { role: "viewer" } }
      assert_response :forbidden
      delete workspace_workspace_membership_path(@workspace, protected_membership)
      assert_response :forbidden
      assert WorkspaceMembership.exists?(protected_membership.id)
    end
    delete workspace_path(@workspace), params: { confirmation: "DELETE WORKSPACE" }
    assert_response :forbidden
    delete workspace_workspace_membership_path(@workspace, membership)
    assert_response :redirect
    assert_not WorkspaceMembership.exists?(membership.id)
  end

  test "owner can elevate joined users but cannot remove or demote the last owner" do
    membership = @workspace.workspace_memberships.create!(user: @other, role: "viewer")
    %w[admin owner].each do |role|
      patch workspace_workspace_membership_path(@workspace, membership), params: { workspace_membership: { role: role } }
      assert_response :redirect
      assert_equal role, membership.reload.role
    end
    delete workspace_workspace_membership_path(@workspace, membership)
    assert_response :forbidden
    assert WorkspaceMembership.exists?(membership.id)
    patch workspace_workspace_membership_path(@workspace, membership), params: { workspace_membership: { role: "translator" } }
    assert_response :redirect
    patch workspace_workspace_membership_path(@workspace, @ownership), params: { workspace_membership: { role: "admin" } }
    assert_response :forbidden
    assert_equal "owner", @ownership.reload.role
    delete workspace_workspace_membership_path(@workspace, @ownership)
    assert_response :forbidden
    assert WorkspaceMembership.exists?(@ownership.id)
    unrelated = Workspace.create!(name: "Other")
    unrelated_membership = unrelated.workspace_memberships.create!(user: @other, role: "viewer")
    patch workspace_workspace_membership_path(@workspace, unrelated_membership), params: { workspace_membership: { role: "admin" } }
    assert_response :not_found
  end

  test "invites persist only low roles and accepting cannot override the offered role" do
    %w[admin owner nonsense].each do |role|
      assert_no_difference "WorkspaceInvite.count" do
        post workspace_workspace_invites_path(@workspace), params: { email: @other.email, role: role }
      end
      assert_response :unprocessable_entity
    end
    post workspace_workspace_invites_path(@workspace), params: { email: @other.email, role: "translator" }
    assert_response :redirect
    invite = @workspace.workspace_invites.sole
    assert_equal "translator", invite.role
    post workspace_workspace_invites_path(@workspace), params: { email: @other.email, role: "viewer" }
    assert_equal "translator", invite.reload.role
    sign_in @other
    patch workspace_invite_path(invite), params: { decision: "accept", role: "owner" }
    assert_response :redirect
    assert_equal "translator", @workspace.workspace_memberships.find_by!(user: @other).role
  end

  test "workspace deletion requires exact confirmation and removes dependent data" do
    project = @workspace.projects.create!(name: "Website")
    invite = @workspace.workspace_invites.create!(email: @other.email)
    delete workspace_path(@workspace), params: { confirmation: "delete workspace" }
    assert_response :unprocessable_entity
    assert Workspace.exists?(@workspace.id)
    assert_select "se-modal#workspace-delete-confirmation[open]"
    delete workspace_path(@workspace), params: { confirmation: "DELETE WORKSPACE" }
    assert_redirected_to workspaces_path
    assert_not Workspace.exists?(@workspace.id)
    assert_not Project.exists?(project.id)
    assert_not WorkspaceInvite.exists?(invite.id)
    assert_not WorkspaceMembership.exists?(@ownership.id)
  end

  test "global owner override does not give global admins sensitive workspace powers" do
    @other.update!(role: :admin)
    sign_in @other
    patch workspace_path(@workspace), params: { workspace: { visibility: "public" }, confirm_visibility: "1" }
    assert_response :forbidden
    @other.update!(role: :owner)
    patch workspace_path(@workspace), params: { workspace: { visibility: "public" }, confirm_visibility: "1" }
    assert_response :redirect
    assert_equal "public", @workspace.reload.visibility
  end

  test "deleting an account cannot strand its workspace without an owner" do
    assert_not @owner.destroy
    assert User.exists?(@owner.id)
    assert WorkspaceMembership.exists?(@ownership.id)
  end
end
