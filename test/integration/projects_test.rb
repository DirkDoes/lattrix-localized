require "test_helper"

class ProjectsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner = users(:one)
    @recipient = users(:two)
    [ @owner, @recipient ].each { |user| user.update!(email_verified_at: Time.current) }
    @owner.update!(role: :member)
    @recipient.update!(role: :guest)
    sign_in @owner
    post projects_path, params: { project: { name: "Localization", visibility: "private", role: "viewer" } }
    @project = Project.order(:created_at).last
  end

  test "creation, validation and tenant-scoped lists" do
    assert_equal "owner", @project.project_memberships.find_by!(user: @owner).role
    assert_no_difference "Project.count" do
      post projects_path, params: { project: { name: "", visibility: "invalid" } }
    end
    assert_response :unprocessable_entity
    assert_select "se-modal#project-create-modal[open][size=medium]"
    get projects_path
    assert_select "se-workspace-card[title='Localization']"
    assert_select "se-sidebar-group[variant=page][href=?]", projects_path do
      assert_select "se-sidebar-button[href=?]", project_path(@project)
    end
    assert_select "se-modal#project-create-modal:not([open]) form[novalidate]"
    sign_in @recipient
    get projects_path
    assert_select "se-workspace-card[title='Localization']", count: 0
    assert_select "se-sidebar-group se-sidebar-button[href=?]", project_path(@project), count: 0
    get project_sheets_path(@project)
    assert_response :not_found
    sign_out @recipient
    get projects_path
    assert_redirected_to new_user_session_path
  end

  test "email-only invites do not disclose account existence and are idempotent" do
    [ @recipient.email.upcase, "future@example.com", @owner.email ].each do |email|
      assert_difference "ProjectInvite.count" do
        post project_project_invites_path(@project), params: { email: " #{email} ", role: "viewer" }
      end
      assert_redirected_to members_project_path(@project)
      assert_equal "User has been invited.", flash[:notice]
    end
    assert_no_difference "ProjectInvite.count" do
      post project_project_invites_path(@project), params: { email: @recipient.email }
    end
    assert_equal "User has been invited.", flash[:notice]
    assert_no_difference "ProjectInvite.count" do
      post project_project_invites_path(@project), params: { email: "invalid" }
    end
    assert_response :unprocessable_entity
    assert_select "se-modal#project-invite-modal[open][size=medium]" do
      assert_select "form[novalidate]"
      assert_select "se-input[value=invalid][error='Enter a valid email address.']"
    end
  end

  test "project roles authorize invites independently of global role" do
    membership = @project.project_memberships.find_by!(user: @owner)
    backup = User.register_verified!(email: "backup@example.com")
    @project.project_memberships.create!(user: backup, role: "owner")
    %w[viewer translator].each do |role|
      membership.update!(role: role)
      assert_no_difference "ProjectInvite.count" do
        post project_project_invites_path(@project), params: { email: @recipient.email }
      end
      assert_response(role == "viewer" ? :not_found : :forbidden)
      get members_project_path(@project)
      assert_select "se-menu[data-members-menu]", count: 0
      assert_select "se-modal#project-invite-modal", count: 0
    end
    membership.update!(role: "admin")
    post project_project_invites_path(@project), params: { email: @recipient.email }
    assert_redirected_to members_project_path(@project)
    sign_in @recipient
    post project_project_invites_path(@project), params: { email: "other@example.com" }
    assert_response :not_found
  end

  test "only recipient can accept or decline and existing roles are preserved" do
    invite = @project.project_invites.create!(email: @recipient.email)
    patch project_invite_path(invite), params: { decision: "accept" }
    assert_response :not_found
    assert invite.reload
    sign_in @recipient
    get project_invites_path
    assert_select "se-title", text: "Localization"
    patch project_invite_path(invite), params: { decision: "invalid" }
    assert_response :unprocessable_entity
    assert_difference "ProjectMembership.count" do
      patch project_invite_path(invite), params: { decision: "accept", role: "owner" }
    end
    assert_equal "viewer", @project.project_memberships.find_by!(user: @recipient).role
    assert_not ProjectInvite.exists?(invite.id)
    patch project_invite_path(invite), params: { decision: "accept" }
    assert_response :not_found
    membership = @project.project_memberships.find_by!(user: @recipient)
    membership.update!(role: "translator")
    invite = @project.project_invites.create!(email: @recipient.email)
    assert_no_difference "ProjectMembership.count" do
      patch project_invite_path(invite), params: { decision: "accept" }
    end
    assert_equal "translator", membership.reload.role
    assert_redirected_to projects_path
    assert_not ProjectInvite.exists?(invite.id)
    invite = @project.project_invites.create!(email: @recipient.email)
    assert_no_difference "ProjectMembership.count" do
      patch project_invite_path(invite), params: { decision: "decline" }
    end
    assert_not ProjectInvite.exists?(invite.id)
  end

  test "invitation remains available to a future verified account and multiple projects" do
    @project.project_invites.create!(email: "newperson@example.com")
    user = User.register_verified!(email: "newperson@example.com")
    sign_in user
    get project_invites_path
    assert_select "se-title", text: "Localization"
    patch project_invite_path(ProjectInvite.find_by!(email: user.email)), params: { decision: "accept" }
    assert_no_difference "Project.count" do
      post projects_path, params: { project: { name: "Second project", visibility: "public" } }
    end
    assert_response :forbidden
    user.update!(role: :admin)
    post projects_path, params: { project: { name: "Second project", visibility: "public" } }
    assert_equal 2, user.project_memberships.count
    get projects_path
    assert_select "se-workspace-card[metadata*='Viewer']"
    assert_select "se-workspace-card[metadata*='Owner']"
  end
  test "sheets and members have separate content" do
    get project_sheets_path(@project)
    assert_response :success
    assert_select "se-title[level=page]", text: "Sheets"
    assert_select "se-empty-illustration"
    assert_select "se-collection", count: 0
    assert_select "se-menu[data-members-menu]", count: 0
    assert_select "se-button[text='All projects']", count: 0
    get members_project_path(@project)
    assert_select "se-nav-tabs[value=members]"
    assert_select "se-title[level=page]", text: "Members"
    assert_select "se-title[level=section]", count: 0
    assert_select "se-collection[type=table]"
    assert_select "se-menu[data-members-menu]"
    sign_in @recipient
    get members_project_path(@project)
    assert_response :not_found
  end

end
