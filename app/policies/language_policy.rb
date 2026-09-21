class LanguagePolicy < ApplicationPolicy
  def create? = ProjectPolicy.new(user, record.project).update?
  def update? = create?
  def archive? = update?
  def restore? = update?
  def destroy? = update?
end
