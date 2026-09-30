class CatalogDraftEdit < ApplicationRecord
  belongs_to :project
  belongs_to :catalog_node
  belongs_to :actor, class_name: "User", optional: true
  before_update { raise ActiveRecord::ReadOnlyRecord }
end
