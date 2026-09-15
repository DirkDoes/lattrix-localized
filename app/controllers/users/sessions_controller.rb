class Users::SessionsController < Devise::SessionsController
  rescue_from AuthRateLimit::Exceeded do |error|
    response.set_header("Retry-After", error.retry_after.to_s)
    render plain: error.message, status: :too_many_requests
  end

  def create
    return head :not_found unless AuthenticationPolicy.enabled?("password")
    email = params.dig(:user, :email).to_s.strip
    AuthRateLimit.check!("password-global", limit: 5000, period: 3600)
    AuthRateLimit.check!("password-ip:#{request.remote_ip}", limit: 30, period: 900)
    AuthRateLimit.check!("password-email:#{email.downcase}", limit: 10, period: 900)
    @password_mode = true

    @email_error = if email.blank?
      "Email can't be blank."
    elsif !email.match?(URI::MailTo::EMAIL_REGEXP)
      "Enter a complete email address."
    end

    if @email_error
      self.resource = resource_class.new(email:)
      render :new, status: :unprocessable_entity
    else
      super do
        session.delete(:security_verified_at)
        session.delete(:security_verified_user)
        session.delete(:security_verified_email)
        session.delete(:link_identity)
        session.delete(:email_challenge_id)
      end
    end
  end

  def destroy
    super
    reset_session
  end
end
