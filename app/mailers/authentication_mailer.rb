class AuthenticationMailer < ApplicationMailer
  def code(email, code)
    mail(to: email, subject: "Your verification code", body: "Your verification code is #{code}. It expires in 10 minutes. If you did not request it, ignore this email.", content_type: "text/plain")
  end

end
