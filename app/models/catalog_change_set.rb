class CatalogChangeSet < ApplicationRecord
  belongs_to :project
  belongs_to :actor, class_name: "User", optional: true
  has_many :catalog_events, -> { order(:sequence) }, dependent: :delete_all
  validates :origin, inclusion: {in: %w[manual restore github]}
end
