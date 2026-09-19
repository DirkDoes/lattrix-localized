require "test_helper"

class InvitationManagementTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner = users(:one)
    @owner.update!(email_verified_at: Time.current, role: :member)
    @recipient = users(:two)
    @recipient.update!(email_verified_at: Time.current, role: :guest)
    @workspace = Workspace.create!(name: "Invitation team")
    @workspace.workspace_memberships.create!(user: @owner, role: "owner")
    @project = @workspace.projects.create!(name: "Private project")
    sign_in @owner
  end

  test "invitations record their sender and admins can search paginate and revoke them" do
    post workspace_workspace_invites_path(@workspace), params: { email: @recipient.email, role: "translator" }
    invite = @workspace.workspace_invites.sole
    assert_equal @owner, invite.invited_by
    20.times { |i| @workspace.workspace_invites.create!(email: "pending-#{i}@example.com") }
    get workspace_workspace_invites_path(@workspace)
    assert_response :success
    assert_select "se-list-row", count: 20
    assert_select "se-pagination[pages='2']"
    get workspace_workspace_invites_path(@workspace), params: { q: @recipient.email }
    assert_select "se-list-row", count: 1
    assert_includes response.body, @owner.name
    assert_select "se-button[text=Revoke]"
    delete workspace_workspace_invite_path(@workspace, invite)
    assert_redirected_to workspace_workspace_invites_path(@workspace)
    assert_not WorkspaceInvite.exists?(invite.id)
  end

  test "pending invitation grants read only access and revocation removes it" do
    invite = @workspace.workspace_invites.create!(email: @recipient.email, role: "translator")
    sign_in @recipient
    get workspace_invites_path
    assert_select "se-button[text='View workspace'][href=?]", workspace_path(@workspace)
    assert_select ".app-grid", count: 0
    get workspace_path(@workspace)
    assert_response :success
    get workspace_project_path(@workspace, @project)
    assert_response :success
    get translations_workspace_project_path(@workspace, @project)
    assert_response :success
    get workspaces_path
    assert_select "se-workspace-card", count: 0
    assert_empty @recipient.workspace_memberships
    post workspace_projects_path(@workspace), params: { project: { name: "Forbidden" } }
    assert_response :forbidden
    get members_workspace_path(@workspace)
    assert_response :not_found
    get workspace_workspace_invites_path(@workspace)
    assert_response :forbidden
    delete workspace_workspace_invite_path(@workspace, invite)
    assert_response :not_found
    assert WorkspaceInvite.exists?(invite.id)
    sign_in @owner
    delete workspace_workspace_invite_path(@workspace, invite)
    assert_not WorkspaceInvite.exists?(invite.id)
    sign_in @recipient
    get overview_path
    assert_response :success
    get workspace_path(@workspace)
    assert_response :not_found
    get workspace_project_path(@workspace, @project)
    assert_response :not_found
  end

  test "invitation management remains tenant scoped and rejects translators" do
    other = Workspace.create!(name: "Other team")
    other.workspace_memberships.create!(user: @owner, role: "owner")
    invite = other.workspace_invites.create!(email: @recipient.email)
    delete workspace_workspace_invite_path(@workspace, invite)
    assert_response :not_found
    @workspace.workspace_memberships.create!(user: @recipient, role: "translator")
    sign_in @recipient
    get workspace_workspace_invites_path(@workspace)
    assert_response :forbidden
    get members_workspace_path(@workspace)
    assert_select "se-menu[data-members-menu]", count: 0
    assert_select "se-list-row se-profile[subtitle]", count: 0
  end
end
