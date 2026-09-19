class WorkspaceInvite < ApplicationRecord
  ROLES = %w[viewer translator].freeze
  belongs_to :workspace
  belongs_to :invited_by, class_name: "User", optional: true
  validates :role, inclusion: { in: ROLES }
  normalizes :email, with: ->(email) { email.strip.downcase }
  validates :email, presence: true, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email, uniqueness: { scope: :workspace_id }

  def accept!(user)
    # Match workspace deletion/membership changes: lock the workspace before its invitation.
    workspace.with_lock do
      with_lock do
        raise ActiveRecord::RecordNotFound unless user.email_verified_at? && email == user.email
        workspace.workspace_memberships.find_or_create_by!(user: user) { |membership| membership.role = role }
        destroy!
      end
    end
  end
end
