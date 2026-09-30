class CatalogKey < ApplicationRecord
  KINDS = %w[scalar branch plural].freeze
  CATEGORIES = %w[zero one two few many other].freeze
  validates :kind, inclusion: {in: KINDS}
  validates :name, presence: true, length: {maximum: 200}, format: {without: /[.\s]/}
  before_update { raise ActiveRecord::ReadOnlyRecord }
end
