class Settings::BaseController < ApplicationController
  layout "settings"
  after_action :verify_authorized
  after_action :verify_policy_scoped, only: :index
  rescue_from Pundit::NotAuthorizedError do
    redirect_to policy(User).index? ? settings_users_path : overview_path,
      alert: "You don't have permission to manage that resource."
  end
end
