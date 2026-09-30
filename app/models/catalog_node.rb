class CatalogNode < ApplicationRecord
  belongs_to :project
  belongs_to :parent, class_name: "CatalogNode", optional: true
  delegated_type :payload, types: %w[CatalogKey CatalogText]
  has_many :catalog_events
end
