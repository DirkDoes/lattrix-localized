class ProjectMembershipPolicy < ApplicationPolicy
  def update?
    project_policy.manage_owners? ||
      (project_policy.update? && %w[viewer translator].include?(record.role))
  end

  def destroy? = update? && record.role != "owner"

  def role_options
    return [] unless update?
    return ["owner"] if record.role == "owner" && !record.project.project_memberships.where(role: "owner").where.not(id: record.id).exists?
    project_policy.manage_owners? ? ProjectMembership::ROLES : %w[viewer translator]
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless access?
      return scope.all if administration?
      readable = user.project_memberships.where(role: %w[translator admin owner]).select(:project_id)
      # A user can always list their own memberships for the project index.
      scope.where(user_id: user.id).or(scope.where(project_id: readable))
    end
  end

  private
  def project_policy
    ProjectPolicy.new(user, record.project)
  end
end
