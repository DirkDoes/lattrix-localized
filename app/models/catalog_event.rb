class CatalogEvent < ApplicationRecord
  belongs_to :catalog_change_set
  belongs_to :catalog_node
  before_update { raise ActiveRecord::ReadOnlyRecord }
end
