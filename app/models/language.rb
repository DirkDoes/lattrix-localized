class Language < ApplicationRecord
  PRESETS = {"en"=>"English", "nl"=>"Dutch", "fr"=>"French", "de"=>"German", "es"=>"Spanish", "pt"=>"Portuguese", "ar"=>"Arabic", "ru"=>"Russian", "ja"=>"Japanese", "zh"=>"Chinese", "en-gb"=>"British English", "en-us"=>"American English"}.freeze
  belongs_to :project
  has_many :membership_languages, dependent: :destroy
  enum :status, {active: "active", archived: "archived", pending_deletion: "pending_deletion"}, validate: true
  normalizes :identifier, with: ->(value) { value.strip }
  normalizes :name, with: ->(value) { value.strip }
  before_validation { self.name = CatalogLocale.name(identifier) if CatalogLocale.valid?(identifier) }
  validates :identifier, inclusion: {in: ->(_) { CatalogLocale::DATA.keys }}
  validates :identifier, uniqueness: {scope: :project_id}

  def archive!
    raise ArgumentError, "The source language cannot be archived" if identifier == project.source_locale
    update!(status: "archived")
  end

end
