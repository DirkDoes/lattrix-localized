class Sheet < ApplicationRecord
  include Sluggable
  belongs_to :project
  belongs_to :default_language, class_name: "Language", optional: true
  has_one :translation_tree, dependent: :destroy
  has_many :sheet_languages, dependent: :destroy
  before_validation :choose_default_language, on: :create
  after_create :create_translation_tree!
  validates :description, length: {maximum: 2000}
  validates :missing_value_behavior, inclusion: {in: %w[omit empty fallback]}
  validates :delimiter, length: {in: 1..3}
  validates :wildcard_format, length: {maximum: 50}
  validate :delimiter_available
  validate :wildcard_format_shape
  validate :translation_settings

  def delimiter_available
    return unless persisted? && will_save_change_to_delimiter? && delimiter&.length&.between?(1, 3)
    if translation_tree.recordings.active.keys.joins("JOIN translation_keys k ON k.id=recordings.recordable_id").where("position(? in k.name)>0", delimiter).exists?
      errors.add(:delimiter, "cannot be changed because existing keys contain this delimiter. Rename those keys first.")
    end
  end

  def wildcard_format_shape
    return if wildcard_format.blank?
    parts = wildcard_format.split("...", -1)
    errors.add(:wildcard_format, "must contain ... between its opening and closing characters") unless parts.length == 2 && parts.all?(&:present?)
  end

  def choose_default_language
    return if default_language_id || !project
    self.default_language = project.languages.active.where(enabled: true).order(:created_at).first

  end

  def active_languages
    project.languages.active.where(enabled: true).or(project.languages.active.where(id: sheet_languages.where(enabled: true).select(:language_id)))
  end

  def translation_settings
    errors.add(:default_language, "must be enabled") if default_language_id && !active_languages.exists?(id: default_language_id)
    if persisted? && will_save_change_to_allow_parent_translations? && !allow_parent_translations?
      conflicts = translation_tree.recordings.active.keys.where(id: translation_tree.recordings.active.texts.select(:parent_id)).where(id: translation_tree.recordings.active.keys.select(:parent_id))
      errors.add(:allow_parent_translations, "cannot be disabled while parent keys have translations") if conflicts.exists?
    end
    if plural_categories.empty? || plural_categories.any? { |name| name.blank? } || plural_categories.uniq != plural_categories
      errors.add(:plural_categories, "must contain distinct nonempty names")
    end
  end
  normalizes :name, with: ->(name) { name.strip }
  normalizes :wildcard_format, with: ->(format) { format.strip }
  validates :slug, uniqueness: { case_sensitive: false, scope: :project_id }
  validates :name, presence: true, length: { maximum: 100 }
  validates :visibility, inclusion: { in: %w[public private] }

  validate :project_capacity, on: :create

  def project_capacity
    errors.add(:base, "A project can contain at most 90 sheets.") if project && project.sheets.count >= 90
  end

  def effective_visibility
    project.visibility == "private" ? "private" : visibility
  end
end
