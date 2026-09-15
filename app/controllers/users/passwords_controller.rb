class Users::PasswordsController < Devise::PasswordsController
  before_action { head :not_found unless AuthenticationPolicy.enabled?("password") }
  before_action :limit_requests, only: [:create, :update]
  rescue_from AuthRateLimit::Exceeded do |error|
    response.set_header("Retry-After", error.retry_after.to_s)
    render plain: error.message, status: :too_many_requests
  end

  def create
    email = params.dig(:user, :email).to_s.strip.downcase
    unless email.length <= 254 && email.match?(URI::MailTo::EMAIL_REGEXP)
      self.resource = resource_class.new(email: email)
      resource.errors.add(:email, "must be a complete email address")
      return render :new, status: :unprocessable_entity
    end
    user = User.find_by(email: email)
    user.with_lock { user.send_reset_password_instructions if user.auth_identities.exists?(provider: "password") } if user
    redirect_to new_user_session_path, notice: "If password sign-in is connected to this email, you will receive password reset instructions."
  end

  private

  def limit_requests
    if action_name == "create"
      AuthRateLimit.request!(request.remote_ip, params.dig(:user, :email).to_s.strip.downcase)
    else
      AuthRateLimit.check!("reset-global", limit: 1000, period: 3600)
      AuthRateLimit.check!("reset-ip:#{request.remote_ip}", limit: 30, period: 900)
    end
  end
end
