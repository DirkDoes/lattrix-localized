require "test_helper"

class InvitationManagementTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner = users(:one)
    @owner.update!(email_verified_at: Time.current, role: :member)
    @recipient = users(:two)
    @recipient.update!(email_verified_at: Time.current, role: :guest)
    @project = Project.create!(name: "Invitation team")
    @project.project_memberships.create!(user: @owner, role: "owner")
    @sheet = @project.sheets.create!(name: "Private sheet")
    sign_in @owner
  end

  test "invitations record their sender and admins can search paginate and revoke them" do
    post project_project_invites_path(@project), params: { email: @recipient.email, role: "translator" }
    invite = @project.project_invites.sole
    assert_equal @owner, invite.invited_by
    20.times { |i| @project.project_invites.create!(email: "pending-#{i}@example.com") }
    get project_project_invites_path(@project)
    assert_response :success
    assert_select "se-list-row", count: 20
    assert_select "se-pagination[pages='2']"
    get project_project_invites_path(@project), params: { q: @recipient.email }
    assert_select "se-list-row", count: 1
    assert_includes response.body, @owner.name
    assert_select "se-button[text=Revoke]"
    delete project_project_invite_path(@project, invite)
    assert_redirected_to project_project_invites_path(@project)
    assert_not ProjectInvite.exists?(invite.id)
  end

  test "pending invitation grants read only access and revocation removes it" do
    invite = @project.project_invites.create!(email: @recipient.email, role: "translator")
    sign_in @recipient
    get project_invites_path
    assert_select "se-button[text='View project'][href=?]", project_path(@project)
    assert_select ".app-grid", count: 0
    get project_sheets_path(@project)
    assert_response :success
    get translations_project_sheet_path(@project, @sheet)
    assert_response :success
    get translations_project_sheet_path(@project, @sheet)
    assert_response :success
    get projects_path
    assert_select "se-workspace-card", count: 0
    assert_empty @recipient.project_memberships
    post project_sheets_path(@project), params: { sheet: { name: "Forbidden" } }
    assert_response :forbidden
    get members_project_path(@project)
    assert_response :not_found
    get project_project_invites_path(@project)
    assert_response :forbidden
    delete project_project_invite_path(@project, invite)
    assert_response :not_found
    assert ProjectInvite.exists?(invite.id)
    sign_in @owner
    delete project_project_invite_path(@project, invite)
    assert_not ProjectInvite.exists?(invite.id)
    sign_in @recipient
    get projects_path
    assert_response :success
    get project_sheets_path(@project)
    assert_response :not_found
    get translations_project_sheet_path(@project, @sheet)
    assert_response :not_found
  end

  test "invitation management remains tenant scoped and rejects translators" do
    other = Project.create!(name: "Other team")
    other.project_memberships.create!(user: @owner, role: "owner")
    invite = other.project_invites.create!(email: @recipient.email)
    delete project_project_invite_path(@project, invite)
    assert_response :not_found
    @project.project_memberships.create!(user: @recipient, role: "translator")
    sign_in @recipient
    get project_project_invites_path(@project)
    assert_response :forbidden
    get members_project_path(@project)
    assert_select "se-menu[data-members-menu]", count: 0
    assert_select "se-list-row se-profile[subtitle]", count: 0
  end
end
