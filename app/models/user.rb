class User < ApplicationRecord
  # ponytail: small converted thumbnails live in the DB; move to object storage if avatar volume becomes material.
  THEME_PREFERENCES = %w[system light dark].freeze
  devise :database_authenticatable, :registerable, :recoverable, :rememberable,
    :validatable, :omniauthable, omniauth_providers: AuthenticationPolicy.providers.values.map(&:to_sym)
  enum :role, { guest: 0, admin: 1, owner: 2 }
  has_many :auth_identities, dependent: :destroy
  has_many :workspace_memberships, dependent: :destroy
  has_many :workspaces, through: :workspace_memberships
  attr_accessor :password_optional
  before_validation :normalize_identity
  before_create :promote_first_user
  before_update :guard_owner_change
  before_destroy :guard_last_owner, prepend: true
  after_save :sync_password_identity
  after_save :sync_email_identity
  validates :theme_preference, inclusion: { in: THEME_PREFERENCES }
  validates :name, length: { maximum: 100 }
  validates :email, length: { maximum: 254 }
  validate do
    errors.add(:password, "must be at most 72 bytes") if password && password.bytesize > 72
  end

  def email_address
    email
  end

  def active_for_authentication?
    super && email_verified_at.present?
  end

  def application_access?
    email_verified_at.present? && banned_at.nil?
  end

  def inactive_message
    :invalid
  end

  def valid_password?(password)
    AuthenticationPolicy.enabled?("password") && auth_identities.exists?(provider: "password") && super
  end

  def available_methods
    auth_identities.pluck(:provider).select { |provider| AuthenticationPolicy.enabled?(provider) }
  end

  def reset_password(new_password, confirmation)
    with_lock do
      unless AuthenticationPolicy.enabled?("password") && auth_identities.exists?(provider: "password")
        errors.add(:reset_password_token, :invalid)
        return false
      end
      super
    end
  end

  def self.register_verified!(email:, method: nil, **attributes)
    transaction do
      connection.execute("LOCK TABLE users IN EXCLUSIVE MODE")
      user = create!(**attributes, email: email, email_verified_at: Time.current, password_optional: true)
      user
    end
  end

  private

  # Email-code eligibility follows verified email; environment flags still gate its use.
  def sync_email_identity
    return unless email_verified_at
    auth_identities.find_or_create_by!(provider: "email_code") { |identity| identity.provider_uid = id }
  end

  # Devise owns password hashing/recovery; identities record which methods are connected.
  def sync_password_identity
    return unless saved_change_to_encrypted_password?
    if encrypted_password.present?
      auth_identities.find_or_create_by!(provider: "password") { |identity| identity.provider_uid = id }
    else
      auth_identities.where(provider: "password").destroy_all
    end
  end

  def password_required?
    return false if password_optional && password.blank? && password_confirmation.blank?
    super
  end

  def normalize_identity
    self.email = email.to_s.strip.downcase
    self.name = email.split("@").first.to_s.humanize if name.blank?
  end

  def promote_first_user
    self.class.connection.execute("LOCK TABLE users IN EXCLUSIVE MODE")
    self.role = :owner if self.class.none?
  end

  def guard_owner_change
    guard_last_owner if role_in_database == "owner" && ((will_save_change_to_role? && !owner?) || (will_save_change_to_banned_at? && banned_at))
  end

  def guard_last_owner
    return unless role_in_database == "owner"
    self.class.connection.execute("LOCK TABLE users IN EXCLUSIVE MODE")
    other_owners = self.class.where(role: :owner, banned_at: nil).where.not(id: id).where.not(email_verified_at: nil)
    if other_owners.none?
      errors.add(:base, "At least one active owner must remain.")
      throw :abort
    end
  end
end
