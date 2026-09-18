class Project < ApplicationRecord
  include Sluggable
  belongs_to :workspace
  normalizes :name, with: ->(name) { name.strip }
  validates :slug, uniqueness: { case_sensitive: false, scope: :workspace_id }
  validates :name, presence: true, length: { maximum: 100 }
  validates :visibility, inclusion: { in: %w[public private] }

  def effective_visibility
    workspace.visibility == "private" ? "private" : visibility
  end
end
