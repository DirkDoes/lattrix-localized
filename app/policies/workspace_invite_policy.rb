class WorkspaceInvitePolicy < ApplicationPolicy
  def index? = access?
  def create?
    WorkspacePolicy.new(user, record.workspace).update?
  end
  def destroy? = create?
  def update?
    access? && record.email == user.email
  end
  class ManagementScope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless access?
      return scope.all if administration?
      scope.where(workspace_id: user.workspace_memberships.where(role: %w[admin owner]).select(:workspace_id))
    end
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      access? ? scope.where(email: user.email) : scope.none
    end
  end
end
