class Users::AuthenticationMethodsController < ApplicationController
  before_action :require_security_verification

  def link
    if params[:provider] == "email_code" && AuthenticationPolicy.enabled?("email_code")
      current_user.with_lock do
        current_user.auth_identities.find_or_create_by!(provider: "email_code") { |identity| identity.provider_uid = current_user.id }
      end
      return redirect_to edit_settings_user_path(current_user), notice: "Email code connected."
    end
    return head :not_found unless AuthenticationPolicy.providers.key?(params[:provider])
    session[:link_identity] = { "user_id" => current_user.id, "provider" => params[:provider], "expires_at" => 5.minutes.from_now.to_i }
    redirect_to edit_settings_user_path(current_user, connect: params[:provider])
  end

  def update
    return head :not_found unless AuthenticationPolicy.enabled?("password")
    attributes = params.require(:user).permit(:password, :password_confirmation)
    if attributes[:password].blank?
      current_user.errors.add(:password, "can't be blank")
    end
    saved = current_user.errors.empty? && current_user.with_lock { current_user.update(attributes) }
    if saved
      bypass_sign_in(current_user)
      redirect_to edit_settings_user_path(current_user), notice: "Password updated."
    else
      @user = current_user
      @can_edit_role = false
      render "settings/users/edit", layout: "settings", status: :unprocessable_entity
    end
  end

  def destroy
    method = params[:provider].to_s
    return head :not_found unless AuthenticationPolicy.enabled?(method)
    if method == "email_code"
      return redirect_to edit_settings_user_path(current_user), alert: "Email-code sign-in cannot be disconnected. You can change your email address instead."
    end
    current_user.with_lock do
      if (current_user.available_methods - [method]).empty?
        return redirect_to edit_settings_user_path(current_user), alert: "Keep at least one enabled sign-in method."
      end
      if method == "password"
        current_user.update!(encrypted_password: "", reset_password_token: nil, reset_password_sent_at: nil, password_optional: true)
      else
        current_user.auth_identities.where(provider: method).destroy_all
      end
    end
    bypass_sign_in(current_user)
    redirect_to edit_settings_user_path(current_user), notice: "Sign-in method removed."
  end

  private

  def require_security_verification
    unless security_verified?
      redirect_to edit_settings_user_path(current_user), alert: "Confirm it's you with a fresh email code before changing sign-in methods."
    end
  end
end
