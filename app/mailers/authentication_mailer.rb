class AuthenticationMailer < ApplicationMailer
  def code(email, code)
    @code = code
    attachments.inline["lattrix-localized.png"] = Rails.root.join("app/assets/images/lattrix-text-localized-email.png").binread
    mail(to: email, subject: "Your verification code") { |format| format.html }
  end
end
