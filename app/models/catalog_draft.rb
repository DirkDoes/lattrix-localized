class CatalogDraft < ApplicationRecord
  belongs_to :project
  belongs_to :catalog_node
  belongs_to :actor, class_name: "User", optional: true
  delegated_type :payload, types: %w[CatalogKey CatalogText]
end
