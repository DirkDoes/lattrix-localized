class ProjectInvite < ApplicationRecord
  ROLES = %w[viewer translator].freeze
  belongs_to :project
  belongs_to :invited_by, class_name: "User", optional: true
  validates :role, inclusion: { in: ROLES }
  normalizes :email, with: ->(email) { email.strip.downcase }
  validates :email, presence: true, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email, uniqueness: { scope: :project_id }

  def accept!(user)
    # Match project deletion/membership changes: lock the project before its invitation.
    project.with_lock do
      with_lock do
        raise ActiveRecord::RecordNotFound unless user.email_verified_at? && email == user.email
        project.project_memberships.find_or_create_by!(user: user) { |membership| membership.role = role }
        destroy!
      end
    end
  end
end
