class Project < ApplicationRecord
  include Sluggable
  belongs_to :workspace
  normalizes :name, with: ->(name) { name.strip }
  validates :slug, uniqueness: { case_sensitive: false, scope: :workspace_id }
  validates :name, presence: true, length: { maximum: 100 }
  validates :visibility, inclusion: { in: %w[public private] }

  validate :workspace_capacity, on: :create

  def workspace_capacity
    errors.add(:base, "A workspace can contain at most 12 projects.") if workspace && workspace.projects.count >= 12
  end

  def effective_visibility
    workspace.visibility == "private" ? "private" : visibility
  end
end
