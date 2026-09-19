class WorkspaceMembership < ApplicationRecord
  MAX_MEMBERS = 200
  ROLES = %w[viewer translator admin owner].freeze
  belongs_to :workspace
  belongs_to :user
  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :workspace_id }

  # Serialize every membership creation/move, including simultaneous invite acceptances.
  around_save :lock_workspace_capacity
  around_destroy :lock_workspace_capacity
  before_save :protect_last_owner, if: -> { role_in_database == "owner" && role != "owner" }
  before_destroy :protect_owner_removal
  before_save :check_workspace_capacity, if: :joining_workspace?

  private

  def joining_workspace?
    new_record? || will_save_change_to_workspace_id?
  end

  def lock_workspace_capacity(&block)
    workspace.with_lock(&block)
  end

  def protect_owner_removal
    return unless role_in_database == "owner"
    return if destroyed_by_association&.active_record == Workspace
    errors.add(:base, "Change this owner to another role before removing their membership.")
    throw :abort
  end

  def protect_last_owner
    return unless role_in_database == "owner"
    return if destroyed_by_association&.active_record == Workspace
    return if workspace.workspace_memberships.where(role: "owner").where.not(id: id).exists?

    errors.add(:base, "Appoint another workspace owner before removing or demoting the last owner.")
    throw :abort
  end

  def check_workspace_capacity
    return if workspace.workspace_memberships.count < MAX_MEMBERS
    errors.add(:base, "This workspace has reached its limit of 200 members.")
    throw :abort
  end
end
