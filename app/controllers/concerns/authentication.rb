module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_user!, unless: :devise_controller?
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :authenticate_user!, **options
    end

    def require_unauthenticated_access(**options)
      allow_unauthenticated_access(**options)
      before_action :redirect_authenticated_user, **options
    end
  end

  private

  def authenticated?
    user_signed_in?
  end

  def redirect_authenticated_user
    redirect_to projects_path if authenticated?
  end
end
