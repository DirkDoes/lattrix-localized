class ProjectInvitePolicy < ApplicationPolicy
  def index? = access?
  def create?
    ProjectPolicy.new(user, record.project).update?
  end
  def destroy? = create?
  def update?
    access? && record.email == user.email
  end
  class ManagementScope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless access?
      return scope.all if administration?
      scope.where(project_id: user.project_memberships.where(role: %w[admin owner]).select(:project_id))
    end
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      access? ? scope.where(email: user.email) : scope.none
    end
  end
end
