class WorkspaceInvite < ApplicationRecord
  belongs_to :workspace
  normalizes :email, with: ->(email) { email.strip.downcase }
  validates :email, presence: true, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email, uniqueness: { scope: :workspace_id }

  def accept!(user)
    with_lock do
      raise ActiveRecord::RecordNotFound unless user.email_verified_at? && email == user.email
      workspace.workspace_memberships.find_or_create_by!(user: user) { |membership| membership.role = "viewer" }
      destroy!
    end
  end
end
