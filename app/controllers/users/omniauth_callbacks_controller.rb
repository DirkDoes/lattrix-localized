class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  def google_oauth2
    complete("google")
  end

  def github
    complete("github")
  end

  def discord
    complete("discord")
  end

  def failure
    session.delete(:link_identity)
    redirect_to(current_user ? edit_settings_user_path(current_user) : new_user_session_path,
      alert: "Provider sign-in was cancelled or failed.")
  end

  private

  def complete(provider)
    return head :not_found unless AuthenticationPolicy.providers.key?(provider)
    AuthRateLimit.check!("oauth-global", limit: 1000, period: 3600)
    AuthRateLimit.check!("oauth-ip:#{request.remote_ip}", limit: 30, period: 3600)
    auth = request.env.fetch("omniauth.auth")
    raise EmailChallenge::Invalid unless auth.provider == AuthenticationPolicy::PROVIDERS.fetch(provider) && auth.uid.present?
    intent = session.delete(:link_identity)
    email = verified_email(provider, auth)
    if email.blank? || email.length > 254 || !email.match?(URI::MailTo::EMAIL_REGEXP)
      return redirect_to(current_user ? edit_settings_user_path(current_user) : new_user_session_path,
        alert: "This provider did not supply a verified email. Verify your email with the provider and try again.")
    end
    identity = AuthIdentity.find_by(provider: provider, provider_uid: auth.uid.to_s)
    display_name = (auth.info.nickname.presence || auth.info.name.presence).to_s.first(100)
    if intent
      raise EmailChallenge::Invalid unless current_user && intent["user_id"] == current_user.id && intent["provider"] == provider && intent["expires_at"].to_i > Time.current.to_i
      raise EmailChallenge::Invalid unless security_verified?
      current_user.with_lock do
        if identity && identity.user_id != current_user.id
          return redirect_to edit_settings_user_path(current_user), alert: "This #{provider == 'github' ? 'GitHub' : provider.capitalize} account is already connected to a different account."
        end
        current_user.auth_identities.find_or_create_by!(provider: provider, provider_uid: auth.uid.to_s).update!(display_name: display_name)
      end
      return redirect_to edit_settings_user_path(current_user), notice: "#{provider.capitalize} linked."
    end
    raise EmailChallenge::Invalid if current_user
    user = identity&.user
    unless user
      # A matching email is not authority to attach a new external identity.
      if User.exists?(email: email)
        return redirect_to new_user_session_path, alert: "An account already uses this email. Sign in using a connected method, then link this provider in Personal settings."
      end
      User.transaction do
        user = User.register_verified!(email: email, name: auth.info.name.to_s.first(100))
        user.auth_identities.create!(provider: provider, provider_uid: auth.uid.to_s, display_name: display_name)
      end
    end
    raise EmailChallenge::Invalid unless user.active_for_authentication?
    identity.update!(display_name: display_name) if identity
    reset_session
    sign_in(user)
    redirect_to overview_path
  rescue EmailChallenge::Invalid, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, AuthRateLimit::Exceeded
    redirect_to(current_user ? edit_settings_user_path(current_user) : new_user_session_path,
      alert: "Unable to sign in or link this account. Use an existing method or contact your administrator.")
  end

  def verified_email(provider, auth)
    raw = auth.extra&.raw_info
    case provider
    when "google"
      verified = raw&.email_verified
      verified = auth.extra&.id_info&.email_verified if verified.nil?
      return unless verified == true || verified == "true"
    when "discord"
      return unless raw&.verified == true
    when "github"
      # The strategy's emails endpoint exposes explicit verification status.
      candidate = Array(auth.extra&.all_emails).find { |entry| entry["primary"] == true && entry["verified"] == true }
      return candidate&.fetch("email", nil)&.strip&.downcase
    end
    auth.info.email.to_s.strip.downcase
  end
end
