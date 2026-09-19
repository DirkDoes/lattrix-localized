require "test_helper"

class WorkspacesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner = users(:one)
    @recipient = users(:two)
    [ @owner, @recipient ].each { |user| user.update!(email_verified_at: Time.current) }
    @owner.update!(role: :member)
    @recipient.update!(role: :guest)
    sign_in @owner
    post workspaces_path, params: { workspace: { name: "Localization", visibility: "private", role: "viewer" } }
    @workspace = Workspace.order(:created_at).last
  end

  test "creation, validation and tenant-scoped lists" do
    assert_equal "owner", @workspace.workspace_memberships.find_by!(user: @owner).role
    assert_no_difference "Workspace.count" do
      post workspaces_path, params: { workspace: { name: "", visibility: "invalid" } }
    end
    assert_response :unprocessable_entity
    assert_select "se-modal#workspace-create-modal[open][size=medium]"
    get workspaces_path
    assert_select "se-workspace-card[title='Localization']"
    assert_select "se-sidebar-group[variant=page][href=?]", workspaces_path do
      assert_select "se-sidebar-button[href=?]", workspace_path(@workspace)
    end
    assert_select "se-modal#workspace-create-modal:not([open]) form[novalidate]"
    sign_in @recipient
    get workspaces_path
    assert_select "se-workspace-card[title='Localization']", count: 0
    assert_select "se-sidebar-group se-sidebar-button[href=?]", workspace_path(@workspace), count: 0
    get workspace_path(@workspace)
    assert_response :not_found
    sign_out @recipient
    get workspaces_path
    assert_redirected_to new_user_session_path
  end

  test "email-only invites do not disclose account existence and are idempotent" do
    [ @recipient.email.upcase, "future@example.com", @owner.email ].each do |email|
      assert_difference "WorkspaceInvite.count" do
        post workspace_workspace_invites_path(@workspace), params: { email: " #{email} ", role: "viewer" }
      end
      assert_redirected_to members_workspace_path(@workspace)
      assert_equal "User has been invited.", flash[:notice]
    end
    assert_no_difference "WorkspaceInvite.count" do
      post workspace_workspace_invites_path(@workspace), params: { email: @recipient.email }
    end
    assert_equal "User has been invited.", flash[:notice]
    assert_no_difference "WorkspaceInvite.count" do
      post workspace_workspace_invites_path(@workspace), params: { email: "invalid" }
    end
    assert_response :unprocessable_entity
    assert_select "se-modal#workspace-invite-modal[open][size=medium]" do
      assert_select "form[novalidate]"
      assert_select "se-input[value=invalid][error='Enter a valid email address.']"
    end
  end

  test "workspace roles authorize invites independently of global role" do
    membership = @workspace.workspace_memberships.find_by!(user: @owner)
    backup = User.register_verified!(email: "backup@example.com")
    @workspace.workspace_memberships.create!(user: backup, role: "owner")
    %w[viewer translator].each do |role|
      membership.update!(role: role)
      assert_no_difference "WorkspaceInvite.count" do
        post workspace_workspace_invites_path(@workspace), params: { email: @recipient.email }
      end
      assert_response(role == "viewer" ? :not_found : :forbidden)
      get members_workspace_path(@workspace)
      assert_select "se-menu[data-members-menu]", count: 0
      assert_select "se-modal#workspace-invite-modal", count: 0
    end
    membership.update!(role: "admin")
    post workspace_workspace_invites_path(@workspace), params: { email: @recipient.email }
    assert_redirected_to members_workspace_path(@workspace)
    sign_in @recipient
    post workspace_workspace_invites_path(@workspace), params: { email: "other@example.com" }
    assert_response :not_found
  end

  test "only recipient can accept or decline and existing roles are preserved" do
    invite = @workspace.workspace_invites.create!(email: @recipient.email)
    patch workspace_invite_path(invite), params: { decision: "accept" }
    assert_response :not_found
    assert invite.reload
    sign_in @recipient
    get workspace_invites_path
    assert_select "se-title", text: "Localization"
    patch workspace_invite_path(invite), params: { decision: "invalid" }
    assert_response :unprocessable_entity
    assert_difference "WorkspaceMembership.count" do
      patch workspace_invite_path(invite), params: { decision: "accept", role: "owner" }
    end
    assert_equal "viewer", @workspace.workspace_memberships.find_by!(user: @recipient).role
    assert_not WorkspaceInvite.exists?(invite.id)
    patch workspace_invite_path(invite), params: { decision: "accept" }
    assert_response :not_found
    membership = @workspace.workspace_memberships.find_by!(user: @recipient)
    membership.update!(role: "translator")
    invite = @workspace.workspace_invites.create!(email: @recipient.email)
    assert_no_difference "WorkspaceMembership.count" do
      patch workspace_invite_path(invite), params: { decision: "accept" }
    end
    assert_equal "translator", membership.reload.role
    assert_redirected_to workspaces_path
    assert_not WorkspaceInvite.exists?(invite.id)
    invite = @workspace.workspace_invites.create!(email: @recipient.email)
    assert_no_difference "WorkspaceMembership.count" do
      patch workspace_invite_path(invite), params: { decision: "decline" }
    end
    assert_not WorkspaceInvite.exists?(invite.id)
  end

  test "invitation remains available to a future verified account and multiple workspaces" do
    @workspace.workspace_invites.create!(email: "newperson@example.com")
    user = User.register_verified!(email: "newperson@example.com")
    sign_in user
    get workspace_invites_path
    assert_select "se-title", text: "Localization"
    patch workspace_invite_path(WorkspaceInvite.find_by!(email: user.email)), params: { decision: "accept" }
    assert_no_difference "Workspace.count" do
      post workspaces_path, params: { workspace: { name: "Second workspace", visibility: "public" } }
    end
    assert_response :forbidden
    user.update!(role: :admin)
    post workspaces_path, params: { workspace: { name: "Second workspace", visibility: "public" } }
    assert_equal 2, user.workspace_memberships.count
    get workspaces_path
    assert_select "se-workspace-card[metadata*='Viewer']"
    assert_select "se-workspace-card[metadata*='Owner']"
  end
  test "dashboard and members have separate content" do
    get workspace_path(@workspace)
    assert_response :success
    assert_select "se-title[level=page]", text: @workspace.name
    assert_select "se-empty-illustration"
    assert_select "se-collection", count: 0
    assert_select "se-menu[data-members-menu]", count: 0
    assert_select "se-button[text='All workspaces']", count: 0
    get members_workspace_path(@workspace)
    assert_select "se-nav-tabs[value=members]"
    assert_select "se-title[level=page]", text: "Members"
    assert_select "se-title[level=section]", count: 0
    assert_select "se-collection[type=table]"
    assert_select "se-menu[data-members-menu]"
    sign_in @recipient
    get members_workspace_path(@workspace)
    assert_response :not_found
  end

end
