class CatalogTag < ApplicationRecord
  belongs_to :project
  before_update { raise ActiveRecord::ReadOnlyRecord }
end
