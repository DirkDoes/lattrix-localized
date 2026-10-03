class CatalogKey < ApplicationRecord
  KINDS = %w[scalar branch plural].freeze
  CATEGORIES = %w[zero one two few many other].freeze
  FILE_GROUP_FORMAT = /\A(?:[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9][a-z0-9_-]*)*)?\z/
  before_validation { self.file_group = file_group.to_s.strip.downcase }
  validates :file_group, length: {maximum: 100}, format: {with: FILE_GROUP_FORMAT}
  validates :kind, inclusion: {in: KINDS}
  validates :name, presence: true, length: {maximum: 200}, format: {without: /[.\s]/}
  before_update { raise ActiveRecord::ReadOnlyRecord }
end
