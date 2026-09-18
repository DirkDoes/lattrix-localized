class Workspace < ApplicationRecord
  include Sluggable
  scope :visible_to, ->(user) { where(visibility: "public").or(where(id: user.workspaces.select(:id))) }

  has_many :projects, dependent: :destroy
  has_many :workspace_memberships, dependent: :destroy
  has_many :users, through: :workspace_memberships
  has_many :workspace_invites, dependent: :destroy
  normalizes :name, with: ->(name) { name.strip }
  validates :slug, uniqueness: { case_sensitive: false }
  validates :name, presence: true, length: { maximum: 100 }
  validates :visibility, inclusion: { in: %w[public private] }
end
