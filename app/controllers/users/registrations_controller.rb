class Users::RegistrationsController < Devise::RegistrationsController
  before_action :password_enabled, except: [:new, :edit, :destroy]
  before_action :registration_enabled, only: :new
  rescue_from AuthRateLimit::Exceeded do |error|
    response.set_header("Retry-After", error.retry_after.to_s)
    render plain: error.message, status: :too_many_requests
  end

  def create
    AuthRateLimit.request!(request.remote_ip, params.dig(:user, :email).to_s.strip.downcase)
    build_resource(sign_up_params)
    resource.valid?
    # Do not disclose existing accounts before the email challenge is completed.
    resource.errors.delete(:email, :taken)
    unless resource.errors.empty?
      clean_up_passwords(resource)
      @password_mode = true
      return render :new, status: :unprocessable_entity
    end
    email = resource.email
    challenge, code = EmailChallenge.issue!(email: email, purpose: "registration", name: resource.name,
      password_digest: resource.encrypted_password)
    session[:email_challenge_id] = challenge.id
    AuthenticationMailer.code(email, code).deliver_now
    redirect_to users_email_code_path
  end

  def update
    head :not_found
  end

  def edit
    redirect_to edit_settings_user_path(current_user)
  end

  def destroy
    unless security_verified? && session[:account_deletion_user] == current_user.id
      return redirect_to edit_settings_user_path(current_user), alert: "Start account deletion again to confirm it's you."
    end
    unless params[:confirmation] == "DELETE MY ACCOUNT"
      return redirect_to edit_settings_user_path(current_user, account_action: "delete"), alert: "Type DELETE MY ACCOUNT exactly to confirm deletion."
    end
    user = current_user
    deleted = User.transaction do
      if user.destroy
        EmailChallenge.where(email: user.email).delete_all
        true
      end
    end
    unless deleted
      return redirect_to edit_settings_user_path(user), alert: user.errors.full_messages.to_sentence
    end
    sign_out(user)
    reset_session
    redirect_to new_user_session_path, notice: "Your account has been permanently deleted."
  end

  private

  def registration_enabled
    head :not_found unless AuthenticationPolicy.enabled?("password") || AuthenticationPolicy.enabled?("email_code")
  end

  def password_enabled
    head :not_found unless AuthenticationPolicy.enabled?("password")
  end
end
