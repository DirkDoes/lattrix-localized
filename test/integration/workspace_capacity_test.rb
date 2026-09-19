require "test_helper"

class WorkspaceCapacityTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "the 200th member joins but the next invite remains pending until there is room" do
    owner = users(:one)
    recipient = users(:two)
    [owner, recipient].each { |user| user.update!(email_verified_at: Time.current) }
    workspace = Workspace.create!(name: "Capacity")
    workspace.workspace_memberships.create!(user: owner, role: "owner")
    rows = 198.times.map { |i| { id: SecureRandom.uuid, email: "capacity-#{i}@example.com", name: "Member #{i}" } }
    User.insert_all!(rows)
    WorkspaceMembership.insert_all!(rows.map { |row| { user_id: row[:id], workspace_id: workspace.id, role: "viewer" } })
    invite = workspace.workspace_invites.create!(email: recipient.email)
    sign_in recipient
    assert_difference "WorkspaceMembership.count", 1 do
      patch workspace_invite_path(invite), params: { decision: "accept" }
    end
    assert_redirected_to workspaces_path
    assert_equal 200, workspace.workspace_memberships.count
    assert_not WorkspaceInvite.exists?(invite.id)

    newcomer = User.create!(email: "overflow@example.com", password_optional: true, email_verified_at: Time.current)
    invite = workspace.workspace_invites.create!(email: newcomer.email)
    sign_out recipient
    sign_in newcomer
    get overview_path
    assert_no_difference "WorkspaceMembership.count" do
      patch workspace_invite_path(invite), params: { decision: "accept" }
    end
    assert_redirected_to workspace_invites_path
    assert_includes flash[:alert], "200 members"
    assert WorkspaceInvite.exists?(invite.id)
    assert workspace.workspace_memberships.find_by!(user: recipient).update(role: "translator")
    duplicate = workspace.workspace_invites.create!(email: recipient.email)
    assert_no_difference "WorkspaceMembership.count" do
      duplicate.accept!(recipient)
    end
    assert_equal "translator", workspace.workspace_memberships.find_by!(user: recipient).role
    workspace.workspace_memberships.find_by!(user_id: rows.first[:id]).destroy!
    assert_difference "WorkspaceMembership.count", 1 do
      patch workspace_invite_path(invite), params: { decision: "accept" }
    end
    assert_redirected_to workspaces_path
  end
end
