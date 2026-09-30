class CatalogReview < ApplicationRecord
  belongs_to :catalog_node
  belongs_to :actor, class_name: "User", optional: true
end
