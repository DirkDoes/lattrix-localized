class WorkspaceMembershipPolicy < ApplicationPolicy
  def update?
    workspace_policy.manage_owners? ||
      (workspace_policy.update? && %w[viewer translator].include?(record.role))
  end

  def destroy? = update? && record.role != "owner"

  def role_options
    return [] unless update?
    return ["owner"] if record.role == "owner" && !record.workspace.workspace_memberships.where(role: "owner").where.not(id: record.id).exists?
    workspace_policy.manage_owners? ? WorkspaceMembership::ROLES : %w[viewer translator]
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless access?
      return scope.all if administration?
      readable = user.workspace_memberships.where(role: %w[translator admin owner]).select(:workspace_id)
      # A user can always list their own memberships for the workspace index.
      scope.where(user_id: user.id).or(scope.where(workspace_id: readable))
    end
  end

  private
  def workspace_policy
    WorkspacePolicy.new(user, record.workspace)
  end
end
