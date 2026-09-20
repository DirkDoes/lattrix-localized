require "test_helper"

class ProjectCapacityTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "the 200th member joins but the next invite remains pending until there is room" do
    owner = users(:one)
    recipient = users(:two)
    [owner, recipient].each { |user| user.update!(email_verified_at: Time.current) }
    project = Project.create!(name: "Capacity")
    project.project_memberships.create!(user: owner, role: "owner")
    rows = 198.times.map { |i| { id: SecureRandom.uuid, email: "capacity-#{i}@example.com", name: "Member #{i}" } }
    User.insert_all!(rows)
    ProjectMembership.insert_all!(rows.map { |row| { user_id: row[:id], project_id: project.id, role: "viewer" } })
    invite = project.project_invites.create!(email: recipient.email)
    sign_in recipient
    assert_difference "ProjectMembership.count", 1 do
      patch project_invite_path(invite), params: { decision: "accept" }
    end
    assert_redirected_to projects_path
    assert_equal 200, project.project_memberships.count
    assert_not ProjectInvite.exists?(invite.id)

    newcomer = User.create!(email: "overflow@example.com", password_optional: true, email_verified_at: Time.current)
    invite = project.project_invites.create!(email: newcomer.email)
    sign_out recipient
    sign_in newcomer
    get projects_path
    assert_no_difference "ProjectMembership.count" do
      patch project_invite_path(invite), params: { decision: "accept" }
    end
    assert_redirected_to project_invites_path
    assert_includes flash[:alert], "200 members"
    assert ProjectInvite.exists?(invite.id)
    assert project.project_memberships.find_by!(user: recipient).update(role: "translator")
    duplicate = project.project_invites.create!(email: recipient.email)
    assert_no_difference "ProjectMembership.count" do
      duplicate.accept!(recipient)
    end
    assert_equal "translator", project.project_memberships.find_by!(user: recipient).role
    project.project_memberships.find_by!(user_id: rows.first[:id]).destroy!
    assert_difference "ProjectMembership.count", 1 do
      patch project_invite_path(invite), params: { decision: "accept" }
    end
    assert_redirected_to projects_path
  end
end
