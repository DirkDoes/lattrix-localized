class Users::EmailCodesController < ApplicationController
  allow_unauthenticated_access
  before_action :authenticate_user!, only: [:security, :change_email]
  rescue_from AuthRateLimit::Exceeded, with: :throttled

  def create
    return head :not_found unless AuthenticationPolicy.enabled?("email_code")
    email = params.dig(:user, :email).to_s.strip.downcase
    name = params.dig(:user, :name).to_s.strip
    @email_error = "Enter a complete email address." unless email.length <= 254 && email.match?(URI::MailTo::EMAIL_REGEXP)
    @name_error = "Name is too long (maximum 100 characters)." if name.length > 100
    if @email_error || @name_error
      @email = email
      @name = name
      return render "users/email_codes/new", status: :unprocessable_entity
    end
    issue(email: email, purpose: "login", name: name)
  end

  def security
    session[:security_next] = params[:next] == "delete" ? "delete" : nil
    if security_verified?
      return finish_security_check
    end
    issue(email: current_user.email, purpose: "security")
  end

  def show
    @challenge = EmailChallenge.find_by(id: session[:email_challenge_id])
    redirect_to new_user_session_path unless @challenge
  end

  def change_email
    unless security_verified?
      return redirect_to edit_settings_user_path(current_user), alert: "Complete the security check before changing your email."
    end
    email = params.dig(:user, :email).to_s.strip.downcase
    unless email.length <= 254 && email.match?(URI::MailTo::EMAIL_REGEXP) && email != current_user.email
      @email_change_error = "Enter a different, complete email address."
      @user = current_user
      @can_edit_role = false
      return render "settings/users/edit", layout: "settings", status: :unprocessable_entity
    end
    issue(email: email, purpose: "email_change")
    session[:email_change] = { "user_id" => current_user.id, "old_email" => current_user.email, "challenge_id" => session[:email_challenge_id] }
  end

  def verify
    AuthRateLimit.check!("verify-global", limit: 5000, period: 3600)
    AuthRateLimit.check!("verify-ip:#{request.remote_ip}", limit: 60, period: 3600)
    @challenge = EmailChallenge.find_by(id: session[:email_challenge_id])
    raise EmailChallenge::Invalid unless @challenge
    permitted = case @challenge.purpose
    when "login" then AuthenticationPolicy.enabled?("email_code")
    when "registration" then AuthenticationPolicy.enabled?("password")
    when "security" then current_user && current_user.email == @challenge.email
    when "email_change"
      intent = session[:email_change]
      security_verified? && intent && intent["user_id"] == current_user.id && intent["old_email"] == current_user.email && intent["challenge_id"] == @challenge.id
    else false
    end
    raise EmailChallenge::Invalid unless permitted
    @challenge.consume!(params[:code])
    if @challenge.purpose == "email_change"
      current_user.with_lock do
        raise EmailChallenge::Invalid unless current_user.email == session[:email_change]["old_email"]
        current_user.update!(email: @challenge.email, email_verified_at: Time.current, reset_password_token: nil, reset_password_sent_at: nil, password_optional: true)
        EmailChallenge.where(email: session[:email_change]["old_email"]).delete_all
      end
      user = current_user
      reset_session
      sign_in(user)
      remember_security_verification(user)
      return redirect_to edit_settings_user_path(user), notice: "Your email address has been changed and verified."
    end
    user = User.find_by(email: @challenge.email)
    if @challenge.purpose == "security"
      raise EmailChallenge::Invalid unless user == current_user
      remember_security_verification(current_user)
      finish_security_check
    else
      if user && (@challenge.purpose == "registration" || (@challenge.purpose == "login" && !user.auth_identities.exists?(provider: "email_code")))
        session.delete(:email_challenge_id)
        return redirect_to new_user_session_path, alert: "An account already uses this email. Sign in using a connected method, then manage your methods in Personal settings."
      end
      user ||= User.register_verified!(email: @challenge.email, name: @challenge.name,
        method: @challenge.purpose == "login" ? "email_code" : "password", encrypted_password: @challenge.password_digest.to_s)
      user.with_lock do
        raise EmailChallenge::Invalid if @challenge.purpose == "login" && !user.auth_identities.exists?(provider: "email_code")
        user.update!(email_verified_at: Time.current, password_optional: true) unless user.email_verified_at
        raise EmailChallenge::Invalid unless user.active_for_authentication?
      end
      reset_session
      sign_in(user)
      remember_security_verification(user)
      redirect_to overview_path
    end
    session.delete(:email_challenge_id)
  rescue EmailChallenge::Invalid, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    @code_error = if @challenge&.purpose == "email_change" && @challenge.consumed_at
      "This email could not be used. Return to settings and request a new code for a different address."
    else
      "The code is invalid or expired. Request a new code and try again."
    end
    render :show, status: :unprocessable_entity
  end

  private

  def finish_security_check
    next_step = session.delete(:security_next)
    session[:account_deletion_user] = current_user.id if next_step == "delete"
    redirect_to edit_settings_user_path(current_user, account_action: next_step)
  end

  def issue(email:, purpose:, name: nil)
    AuthRateLimit.request!(request.remote_ip, email)
    challenge, code = EmailChallenge.issue!(email: email, purpose: purpose, name: name)
    session[:email_challenge_id] = challenge.id
    AuthenticationMailer.code(email, code).deliver_now
    redirect_to users_email_code_path
  end

  def throttled(error)
    response.set_header("Retry-After", error.retry_after.to_s)
    flash.now[:alert] = error.message
    @challenge = EmailChallenge.find_by(id: session[:email_challenge_id])
    if @challenge && @challenge.expires_at > Time.current && !@challenge.consumed_at
      render :show, status: :too_many_requests
    elsif current_user
      redirect_to edit_settings_user_path(current_user), alert: flash.now[:alert]
    else
      render :new, status: :too_many_requests
    end
  end
end
