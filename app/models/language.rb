class Language < ApplicationRecord
  PRESETS = {"en"=>"English", "nl"=>"Dutch", "fr"=>"French", "de"=>"German", "es"=>"Spanish", "pt"=>"Portuguese", "ar"=>"Arabic", "ru"=>"Russian", "ja"=>"Japanese", "zh"=>"Chinese", "en-gb"=>"British English", "en-us"=>"American English"}.freeze
  belongs_to :project
  has_many :membership_languages, dependent: :destroy
  has_many :language_identifiers, dependent: :destroy
  after_create { project.identifier_sets.each { |set| set.language_identifiers.create!(language: self, identifier: identifier) } }
  has_many :sheet_languages, dependent: :destroy
  enum :status, {active: "active", archived: "archived", pending_deletion: "pending_deletion"}, validate: true
  normalizes :identifier, with: ->(value) { value.strip.downcase }
  normalizes :name, with: ->(value) { value.strip }
  validates :name, presence: true
  validates :identifier, format: {with: /\A[a-z0-9]+([-_][a-z0-9]+)*\z/}, uniqueness: {scope: :project_id}
  validate :preserve_default, if: -> { enabled_in_database && !enabled? }

  def archive!
    raise ArgumentError, "Change the default language for #{project.sheets.where(default_language_id: id).pluck(:name).join(', ')} first" if project.sheets.where(default_language_id: id).exists?
    update!(status: "archived")
  end

  def schedule_deletion!
    raise ArgumentError, "Only archived languages can be permanently deleted" unless archived?
    update!(status: "pending_deletion")
    DeleteLanguageJob.perform_later(id)
  end
  private
  def preserve_default
    affected = project.sheets.where(default_language_id: id).where.not(id: sheet_languages.where(enabled: true).select(:sheet_id))
    errors.add(:enabled, "is required as a default language by #{affected.pluck(:name).join(', ')}") if affected.exists?
  end
end
