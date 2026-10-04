class ProjectPolicy < ApplicationPolicy
  def index? = access?
  def administration_index? = administration?
  def show?
    Scope.new(user, Project).resolve.exists?(id: record.id)
  end
  def create?
    access? && (administration? || user.member?)
  end
  def new?
    create? && (!user.member? || user.project_memberships.where(role: "owner").count < 3)
  end
  def members?
    access? && (administration? || %w[translator admin owner].include?(membership&.role))
  end
  def update?
    access? && (administration? || %w[admin owner].include?(membership&.role))
  end
  def change_visibility?
    access? && (user.owner? || membership&.role == "owner")
  end
  def change_slug? = change_visibility?
  def change_locale_limits? = change_visibility?
  def destroy? = change_visibility?
  def manage_owners? = change_visibility?
  def view_member_emails? = update?
  def settings? = update?
  def history? = members?
  def pending? = members? && record.linked?
  def edit_locale?(locale)
    return false unless access? && record.languages.active.exists?(identifier: locale)
    update? || (membership&.role == "translator" && membership.languages.exists?(identifier: locale))
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.where(visibility: "public") unless user
      return scope.none unless access?
      return scope.all if administration?
      scope.where(visibility: "public").or(scope.where(id: user.projects.select(:id)))
        .or(scope.where(id: ProjectInvite.where(email: user.email).select(:project_id)))
    end
  end

  private
  def membership
    # Read afresh when a controller reauthorizes after acquiring the project lock.
    record.project_memberships.find_by(user: user)
  end
end
