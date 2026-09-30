class GithubAppConfigurationPolicy < ApplicationPolicy
  def show? = administration?
  def update? = access? && user.owner?
end
