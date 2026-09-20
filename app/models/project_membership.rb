class ProjectMembership < ApplicationRecord
  MAX_MEMBERS = 200
  ROLES = %w[viewer translator admin owner].freeze
  belongs_to :project
  belongs_to :user
  has_many :membership_languages, dependent: :destroy
  has_many :languages, through: :membership_languages
  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :project_id }

  # Serialize every membership creation/move, including simultaneous invite acceptances.
  around_save :lock_project_capacity
  around_destroy :lock_project_capacity
  before_save :protect_last_owner, if: -> { role_in_database == "owner" && role != "owner" }
  before_destroy :protect_owner_removal
  before_save :check_project_capacity, if: :joining_project?

  private

  def joining_project?
    new_record? || will_save_change_to_project_id?
  end

  def lock_project_capacity(&block)
    project.with_lock(&block)
  end

  def protect_owner_removal
    return unless role_in_database == "owner"
    return if destroyed_by_association&.active_record == Project
    errors.add(:base, "Change this owner to another role before removing their membership.")
    throw :abort
  end

  def protect_last_owner
    return unless role_in_database == "owner"
    return if destroyed_by_association&.active_record == Project
    return if project.project_memberships.where(role: "owner").where.not(id: id).exists?

    errors.add(:base, "Appoint another project owner before removing or demoting the last owner.")
    throw :abort
  end

  def check_project_capacity
    return if project.project_memberships.count < MAX_MEMBERS
    errors.add(:base, "This project has reached its limit of 200 members.")
    throw :abort
  end
end
