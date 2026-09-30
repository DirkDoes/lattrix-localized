class GithubAppConfiguration < ApplicationRecord
  # Separate encryption purpose; retain secret_key_base when moving this database.
  key = ActiveRecord::Encryption::Key.new(Rails.application.key_generator.generate_key('github-app-configuration', 32))
  encrypts :private_key, :webhook_secret, key_provider: ActiveRecord::Encryption::KeyProvider.new(key)

  validates :app_id, format: {with: /\A[1-9]\d*\z/}
  validates :private_key, presence: true
  validates :webhook_secret, length: {minimum: 32}
  validate :valid_private_key
  validate :keep_connected_app

  def self.current
    find_by(id: 1) || new(id: 1, app_id: ENV['GH_APP_ID'], private_key: ENV['GH_APP_PRIVATE_KEY'], webhook_secret: ENV['GH_WEBHOOK_SECRET'])
  end

  def configured? = app_id.present? && private_key.present? && webhook_secret.present?

  private

  def valid_private_key
    self.private_key = private_key.to_s.gsub('\\n', "\n").strip
    rsa = OpenSSL::PKey::RSA.new(private_key)
    errors.add(:private_key, 'must be an RSA private key of at least 2048 bits') unless rsa.private? && rsa.n.num_bits >= 2048
  rescue OpenSSL::PKey::RSAError, ArgumentError
    errors.add(:private_key, 'must be a valid RSA private key in PEM format')
  end

  def keep_connected_app
    previous = persisted? ? app_id_in_database : ENV['GH_APP_ID']
    if previous.present? && previous != app_id && Project.where.not(repository: [nil, '']).exists?
      errors.add(:app_id, 'cannot change while projects are connected; disconnect them first')
    end
  end
end
