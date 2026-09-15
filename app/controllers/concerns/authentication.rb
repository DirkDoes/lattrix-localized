module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_user!, unless: :devise_controller?
    helper_method :authenticated?, :admin?, :owner?, :settings_access?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :authenticate_user!, **options
    end

    def require_unauthenticated_access(**options)
      allow_unauthenticated_access(**options)
      before_action :redirect_authenticated_user, **options
    end

    def require_settings_access(**options)
      before_action :ensure_settings_access, **options
    end

    def require_owner(**options)
      before_action :ensure_owner, **options
    end
  end

  private

  def authenticated?
    user_signed_in?
  end

  def admin?
    current_user&.admin?
  end

  def owner?
    current_user&.owner?
  end

  def settings_access?
    admin? || owner?
  end

  def ensure_settings_access
    return if settings_access?

    redirect_to overview_path, alert: "You don't have permission to access that page."
  end

  def ensure_owner
    return if owner?

    redirect_to settings_users_path, alert: "Only owners can perform that action."
  end

  def redirect_authenticated_user
    redirect_to overview_path if authenticated?
  end
end
