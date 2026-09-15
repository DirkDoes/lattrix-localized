class EmailChallenge < ApplicationRecord
  class Invalid < StandardError; end
  EXPIRY = 10.minutes
  MAX_ATTEMPTS = 5

  def self.digest_for(id, code)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "email-code:#{id}:#{code}")
  end

  def self.issue!(email:, purpose:, name: nil, password_digest: nil)
    where("expires_at < ?", Time.current).delete_all
    code = SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")
    # Serializes replacement so a resend always invalidates the preceding code.
    transaction do
      connection.execute("SELECT pg_advisory_xact_lock(#{Digest::SHA256.hexdigest(email)[0, 15].to_i(16)})")
      where(email: email, purpose: purpose).delete_all
      challenge = new(id: SecureRandom.uuid, email: email, purpose: purpose, name: name,
        password_digest: password_digest, expires_at: EXPIRY.from_now)
      challenge.digest = digest_for(challenge.id, code)
      challenge.save!
      [challenge, code]
    end
  end

  def consume!(code)
    valid = false
    with_lock do
      if consumed_at.nil? && expires_at > Time.current && attempts < MAX_ATTEMPTS
        self.attempts += 1
        valid = code.to_s.match?(/\A\d{6}\z/) && ActiveSupport::SecurityUtils.secure_compare(digest, self.class.digest_for(id, code))
        self.consumed_at = Time.current if valid
        save!
      end
    end
    raise Invalid unless valid
    self
  end
end
