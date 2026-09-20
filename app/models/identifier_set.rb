class IdentifierSet < ApplicationRecord
  belongs_to :project
  has_many :language_identifiers, dependent: :destroy
  validates :name, presence: true, length: {maximum: 80}, uniqueness: {scope: :project_id}
  validates :description, length: {maximum: 1000}
end
