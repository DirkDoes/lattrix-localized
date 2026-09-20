class LanguagePolicy < ApplicationPolicy
  def create? = ProjectPolicy.new(user, record.project).update?
  def update? = create?
end
