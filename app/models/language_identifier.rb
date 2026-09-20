class LanguageIdentifier < ApplicationRecord
  belongs_to :identifier_set
  belongs_to :language
  normalizes :identifier, with: ->(value) { value.strip }
  validates :identifier, format: {with: /\A[a-zA-Z0-9]+([-_][a-zA-Z0-9]+)*\z/}, length: {maximum: 80}, uniqueness: {scope: :identifier_set_id}
  validate { errors.add(:language, "belongs to another project") if language.project_id != identifier_set.project_id }
end
