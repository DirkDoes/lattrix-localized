class WorkspaceMembership < ApplicationRecord
  ROLES = %w[viewer translator admin owner].freeze
  belongs_to :workspace
  belongs_to :user
  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :workspace_id }

  def can_invite?
    %w[admin owner].include?(role)
  end
end
