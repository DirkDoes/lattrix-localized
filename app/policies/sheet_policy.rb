class SheetPolicy < ApplicationPolicy
  def show?
    Scope.new(user, Sheet).resolve.exists?(id: record.id)
  end
  def translations? = show?
  def settings? = create?
  def update? = create?
  def image? = show?
  def change_slug? = ProjectPolicy.new(user, record.project).change_slug?
  def export? = show?
  def manage_keys? = create?
  def reveal_plurals?
    access? && show? && (create? || record.project.project_memberships.exists?(user: user, role: "translator"))
  end
  def edit_language?(language)
    return false unless access? && show? && language && record.active_languages.exists?(id: language.id)
    return true if create?
    membership = record.project.project_memberships.find_by(user: user, role: "translator")
    membership && membership.languages.exists?(id: language.id)
  end
  def create?
    ProjectPolicy.new(user, record.project).update?
  end
  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.where(visibility: "public", project_id: Project.where(visibility: "public").select(:id)) unless user
      return scope.none unless access?
      return scope.all if administration?
      scope.where(project_id: user.projects.select(:id))
        .or(scope.where(project_id: ProjectInvite.where(email: user.email).select(:project_id))).or(
        scope.where(visibility: "public", project_id: Project.where(visibility: "public").select(:id))
      )
    end
  end
end
