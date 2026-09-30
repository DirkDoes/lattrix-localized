class CatalogText < ApplicationRecord
  validates :value, length: {maximum: 100_000}
  validates :locale, inclusion: {in: ->(_) { CatalogLocale::DATA.keys }}
  before_update { raise ActiveRecord::ReadOnlyRecord }
end
