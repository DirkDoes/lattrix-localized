class ProjectPolicy < ApplicationPolicy
  def show?
    Scope.new(user, Project).resolve.exists?(id: record.id)
  end
  def translations? = show?
  def create?
    WorkspacePolicy.new(user, record.workspace).update?
  end
  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.where(visibility: "public", workspace_id: Workspace.where(visibility: "public").select(:id)) unless user
      return scope.none unless access?
      return scope.all if administration?
      scope.where(workspace_id: user.workspaces.select(:id))
        .or(scope.where(workspace_id: WorkspaceInvite.where(email: user.email).select(:workspace_id))).or(
        scope.where(visibility: "public", workspace_id: Workspace.where(visibility: "public").select(:id))
      )
    end
  end
end
