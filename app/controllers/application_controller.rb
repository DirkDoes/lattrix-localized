class ApplicationController < ActionController::Base
  include Authentication

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :configure_permitted_parameters, if: :devise_controller?
  prepend_before_action :enforce_application_access
  helper_method :overlay_flash_messages, :security_verified?

  protected

  def enforce_application_access
    # Do not trigger Warden's password strategy before the sign-in rate limits run.
    return if controller_path == "users/sessions" && %w[create destroy].include?(action_name)
    return unless current_user

    return if current_user.application_access?

    response.set_header("Cache-Control", "no-store")
    render "users/access_denied", layout: "application", status: :forbidden
  end

  def security_verified?
    current_user && session[:security_verified_user] == current_user.id && session[:security_verified_email] == current_user.email && session[:security_verified_at].to_i > 10.minutes.ago.to_i
  end

  def remember_security_verification(user)
    session[:security_verified_user] = user.id
    session[:security_verified_email] = user.email
    session[:security_verified_at] = Time.current.to_i
  end

  def after_sign_in_path_for(_resource)
    stored_location_for(:user) || overview_path
  end

  def after_sign_out_path_for(_resource_or_scope)
    root_path
  end

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:name])
    devise_parameter_sanitizer.permit(:account_update, keys: [:name, :theme_preference])
  end

  def overlay_flash_messages
    flash.each_with_object([]) do |(type, message), messages|
      next if message.blank? || type.to_s == "timedout"

      messages << {
        tone: flash_tone_for(type),
        message: Array(message).join(", ")
      }
    end
  end

  def flash_tone_for(type)
    case type.to_sym
    when :notice, :success
      "success"
    when :alert, :error
      "error"
    when :warning
      "warning"
    when :info
      "info"
    else
      "info"
    end
  end
end
