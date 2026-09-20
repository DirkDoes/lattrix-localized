class TranslationKey < ApplicationRecord
  include Recordable
  PLURAL_CATEGORIES = %w[zero one two few many other].freeze
  validates :name, format: {without: /[[:space:]]/, message: "cannot contain whitespace"}
  validates :description, length: {maximum: 4000}
  validates :name, presence: true, length: {maximum: 200}
end
