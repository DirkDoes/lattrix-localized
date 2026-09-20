class Project < ApplicationRecord
  include Sluggable
  has_many :identifier_sets, dependent: :destroy
  has_many :export_requests, dependent: :destroy
  after_create { identifier_sets.create!(name: "Default") }
  has_many :languages, dependent: :nullify

  has_many :sheets, dependent: :destroy
  has_many :project_memberships, dependent: :destroy
  has_many :users, through: :project_memberships
  has_many :project_invites, dependent: :destroy
  normalizes :name, with: ->(name) { name.strip }
  validates :slug, uniqueness: { case_sensitive: false }
  validates :name, presence: true, length: { maximum: 100 }
  validates :visibility, inclusion: { in: %w[public private] }
end
