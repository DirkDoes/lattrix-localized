class AuthIdentity < ApplicationRecord
  belongs_to :user
  validates :provider, inclusion: { in: AuthenticationPolicy::PROVIDERS.keys + %w[password email_code] }
  validates :provider_uid, presence: true, uniqueness: { scope: :provider }
  validates :provider, uniqueness: { scope: :user_id }
end
