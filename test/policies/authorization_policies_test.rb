require "test_helper"

class AuthorizationPoliciesTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    @other = users(:two)
    @other.update!(email_verified_at: Time.current)
    @public = Project.create!(name: "Public policy", visibility: "public")
    @private = Project.create!(name: "Private policy")
    @public_sheet = @public.sheets.create!(name: "Public", visibility: "public")
    @private_sheet = @public.sheets.create!(name: "Private")
    @hidden_sheet = @private.sheets.create!(name: "Hidden", visibility: "public")
  end

  test "global roles and project roles retain the existing permission matrix" do
    %w[guest member admin owner].each do |role|
      @user.role = role
      privileged = %w[admin owner].include?(role)
      assert_equal role != "guest", ProjectPolicy.new(@user, Project).create?
      assert_equal privileged, UserPolicy.new(@user, User).index?
      assert_equal privileged, ProjectPolicy.new(@user, @private).show?
      assert_equal privileged, ProjectPolicy.new(@user, @public).update?
      assert_equal privileged, SheetPolicy.new(@user, @private_sheet).show?
      assert_equal privileged, SheetPolicy.new(@user, @hidden_sheet).show?
      assert SheetPolicy.new(@user, @public_sheet).show?
    end
    @user.role = :guest
    membership = @private.project_memberships.create!(user: @user, role: "viewer")
    %w[viewer translator admin owner].each do |role|
      membership.update!(role: role)
      assert_equal role != "viewer", ProjectPolicy.new(@user, @private).members?
      assert SheetPolicy.new(@user, @hidden_sheet).show?
      assert_equal %w[admin owner].include?(role), SheetPolicy.new(@user, @private.sheets.new).create?
    end
  end

  test "scopes hide private tenants and invitations even from unrelated global owners" do
    invite = @private.project_invites.create!(email: @user.email)
    unrelated = @private.project_invites.create!(email: @other.email)
    assert_equal [@public.id, @private.id].sort, ProjectPolicy::Scope.new(@user, Project).resolve.pluck(:id).sort
    assert_equal [@public_sheet.id, @hidden_sheet.id].sort, SheetPolicy::Scope.new(@user, Sheet).resolve.pluck(:id).sort
    assert_empty ProjectMembershipPolicy::Scope.new(@user, ProjectMembership).resolve
    %w[guest owner].each do |role|
      @user.role = role
      assert_equal [invite.id], ProjectInvitePolicy::Scope.new(@user, ProjectInvite).resolve.pluck(:id)
      assert_not ProjectInvitePolicy.new(@user, unrelated).update?
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
    assert_not ProjectPolicy.new(nil, Project).create?
    assert_equal [@public_sheet.id], SheetPolicy::Scope.new(nil, Sheet).resolve.pluck(:id)
    @user.role = :owner
    @user.banned_at = Time.current
    assert_not UserPolicy.new(@user, @other).update?
    assert_empty ProjectPolicy::Scope.new(@user, Project).resolve
    assert_raises(NotImplementedError) { ApplicationPolicy::Scope.new(@user, User).resolve }
  end
end
