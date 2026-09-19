class UserPolicy < ApplicationPolicy
  def index? = administration?
  def update?
    access? && (record == user || user.owner? || (user.admin? && !record.owner?))
  end
  def ban?
    administration? && record != user && (user.owner? || !record.owner?)
  end
  def destroy?
    access? && user.owner? && record != user && !record.owner?
  end
  def manage_account?
    access? && record == user
  end
  def role_options
    return [] unless administration? && update?
    return ["owner"] if record.owner? && !User.where(role: :owner, banned_at: nil).where.not(email_verified_at: nil).where.not(id: record.id).exists?
    user.owner? ? User.roles.keys : %w[guest member admin]
  end
  def permitted_attributes
    [:name] + (record == user ? [:theme_preference] : []) + (role_options.any? ? [:role] : [])
  end
  # Only used after the controller resolves a valid signed photo token.
  def public_photo?
    record.present? && record.profile_photo.present?
  end
  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless access?
      administration? ? scope.all : scope.where(id: user.id)
    end
  end
end
