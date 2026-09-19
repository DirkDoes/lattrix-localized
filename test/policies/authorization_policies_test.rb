require "test_helper"

class AuthorizationPoliciesTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    @other = users(:two)
    @other.update!(email_verified_at: Time.current)
    @public = Workspace.create!(name: "Public policy", visibility: "public")
    @private = Workspace.create!(name: "Private policy")
    @public_project = @public.projects.create!(name: "Public", visibility: "public")
    @private_project = @public.projects.create!(name: "Private")
    @hidden_project = @private.projects.create!(name: "Hidden", visibility: "public")
  end

  test "global roles and workspace roles retain the existing permission matrix" do
    %w[guest member admin owner].each do |role|
      @user.role = role
      privileged = %w[admin owner].include?(role)
      assert_equal role != "guest", WorkspacePolicy.new(@user, Workspace).create?
      assert_equal privileged, UserPolicy.new(@user, User).index?
      assert_equal privileged, WorkspacePolicy.new(@user, @private).show?
      assert_equal privileged, WorkspacePolicy.new(@user, @public).update?
      assert_equal privileged, ProjectPolicy.new(@user, @private_project).show?
      assert_equal privileged, ProjectPolicy.new(@user, @hidden_project).show?
      assert ProjectPolicy.new(@user, @public_project).show?
    end
    @user.role = :guest
    membership = @private.workspace_memberships.create!(user: @user, role: "viewer")
    %w[viewer translator admin owner].each do |role|
      membership.update!(role: role)
      assert_equal role != "viewer", WorkspacePolicy.new(@user, @private).members?
      assert ProjectPolicy.new(@user, @hidden_project).show?
      assert_equal %w[admin owner].include?(role), ProjectPolicy.new(@user, @private.projects.new).create?
    end
  end

  test "scopes hide private tenants and invitations even from unrelated global owners" do
    invite = @private.workspace_invites.create!(email: @user.email)
    unrelated = @private.workspace_invites.create!(email: @other.email)
    assert_equal [@public.id, @private.id].sort, WorkspacePolicy::Scope.new(@user, Workspace).resolve.pluck(:id).sort
    assert_equal [@public_project.id, @hidden_project.id].sort, ProjectPolicy::Scope.new(@user, Project).resolve.pluck(:id).sort
    assert_empty WorkspaceMembershipPolicy::Scope.new(@user, WorkspaceMembership).resolve
    %w[guest owner].each do |role|
      @user.role = role
      assert_equal [invite.id], WorkspaceInvitePolicy::Scope.new(@user, WorkspaceInvite).resolve.pluck(:id)
      assert_not WorkspaceInvitePolicy.new(@user, unrelated).update?
    end
  end

  test "admins cannot change owners or delete users and guests cannot promote themselves" do
    @user.role = :admin
    @other.role = :owner
    %i[update? ban? destroy?].each { |action| assert_not UserPolicy.new(@user, @other).public_send(action) }
    assert_empty UserPolicy.new(@user, @other).role_options
    @other.role = :member
    assert UserPolicy.new(@user, @other).update?
    assert UserPolicy.new(@user, @other).ban?
    assert_not UserPolicy.new(@user, @other).destroy?
    assert_not_includes UserPolicy.new(@user, @other).role_options, "owner"
    @user.role = :guest
    assert_equal [:name, :theme_preference], UserPolicy.new(@user, @user).permitted_attributes
    assert_not UserPolicy.new(@user, @other).manage_account?
    assert_equal [@user.id], UserPolicy::Scope.new(@user, User).resolve.pluck(:id)
  end

  test "policies deny anonymous and banned accounts and require explicit scopes" do
    assert_not ApplicationPolicy.new(nil, nil).access?
    assert_not WorkspacePolicy.new(nil, Workspace).create?
    assert_equal [@public_project.id], ProjectPolicy::Scope.new(nil, Project).resolve.pluck(:id)
    @user.role = :owner
    @user.banned_at = Time.current
    assert_not UserPolicy.new(@user, @other).update?
    assert_empty WorkspacePolicy::Scope.new(@user, Workspace).resolve
    assert_raises(NotImplementedError) { ApplicationPolicy::Scope.new(@user, User).resolve }
  end
end
