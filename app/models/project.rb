class Project < ApplicationRecord
  LOCALE_LIMITS = {max_locale_files: 500, max_locale_file_mb: 5, max_locale_total_mb: 30}.freeze
  PR_CHECKS = {
    "source_keys" => ["Source-language structure", "Target translations must correspond to a source key. The source language must be present."],
    "scalar_placeholders" => ["Scalar placeholders", "Ordinary translations must use exactly the same placeholders as their source."],
    "plural_completeness" => ["Plural completeness", "Every translated plural group must contain all forms required by its language."],
    "count_placeholders" => ["Count placeholders", "Require %{count} in other/few/many; allow it in zero/one/two, and reject it outside plurals."]
  }.freeze
  attr_accessor :settings_actor
  validates :pluralization_mode, inclusion: {in: %w[off simple cldr]}
  validates(*LOCALE_LIMITS.keys, numericality: {only_integer: true, greater_than: 0})
  validate :validate_locale_limits
  validate :validate_pr_checks
  def pluralization? = pluralization_mode != "off"
  def plural_categories(locale) = pluralization_mode == "simple" ? %w[one other] : pluralization? ? CatalogLocale.categories(locale) : []
  def pr_check?(key) = pr_validation_checks.fetch(key.to_s, true)
  def validate_locale_limits
    LOCALE_LIMITS.each do |field, ceiling|
      next if settings_actor&.owner? || (!new_record? && !will_save_change_to_attribute?(field))
      errors.add(field, "must be at most #{ceiling}; contact an application owner for a higher limit") if public_send(field).to_i > ceiling
    end
  end
  def validate_pr_checks
    unless pr_validation_checks.is_a?(Hash) && (pr_validation_checks.keys - PR_CHECKS.keys).empty? && pr_validation_checks.values.all? { |value| value == true || value == false }
      errors.add(:pr_validation_checks, "contains unknown checks or invalid values")
    end
  end
  before_validation :normalize_completion_terms
  validate :validate_completion_terms

  def normalize_completion_terms
    self.completion_terms = Array(completion_terms).map do |term|
      {"text" => term.fetch("text", "").to_s.strip, "description" => term.fetch("description", "").to_s.strip}
    end.reject { |term| term.values.all?(&:blank?) }.uniq { |term| term["text"].downcase }
  end

  def validate_completion_terms
    if completion_terms.size > 200 || completion_terms.any? { |term| term["text"].blank? || term["text"].length > 100 || term["description"].length > 300 }
      errors.add(:completion_terms, "Use up to 200 terms, each with a name of 1–100 characters and an optional description of up to 300 characters.")
    end
  end

  include Sluggable
  has_many :languages, dependent: :destroy
  has_many :catalog_nodes, dependent: :delete_all
  has_many :catalog_change_sets, dependent: :delete_all
  has_many :catalog_events, through: :catalog_change_sets
  has_many :catalog_drafts, dependent: :delete_all
  has_many :catalog_draft_edits, dependent: :delete_all
  has_many :catalog_git_revisions, dependent: :delete_all
  has_many :catalog_tags, dependent: :delete_all
  validates :source_locale, inclusion: {in: ->(_) { CatalogLocale::DATA.keys }}
  validates :repository, format: {with: /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/}, allow_blank: true
  validates :locale_directory, format: {with: /\A[A-Za-z0-9_-]+(?:\/[A-Za-z0-9_-]+)*\z/}
  after_create { languages.create!(identifier: source_locale) }
  def linked? = repository.present?
  def sync_busy? = %w[queued running].include?(sync_status) && sync_requested_at && sync_requested_at > 30.minutes.ago
  def writable? = sync_error.blank? && !sync_busy?
  def sync_feedback
    expired = %w[queued running].include?(sync_status) && !sync_busy?
    status = expired ? "failed" : sync_status
    message = if expired
      "Synchronization did not finish. Please retry; if this persists, check the background worker."
    elsif status == "queued"
      "Synchronization queued. Waiting for the background worker…"
    elsif status == "running"
      "Synchronizing with GitHub… The catalog is temporarily read-only."
    else
      sync_message
    end
    {status: status, busy: !!sync_busy?, message: message, token: [sync_job_id, status, sync_finished_at&.iso8601(6)]}
  end
  def change_source_locale!(locale, expected:)
    with_lock do
      raise ActiveRecord::StaleObjectError.new(self, "change source language") unless revision.to_s == expected.to_s
      raise ArgumentError, "Repair synchronization first" unless writable?
      raise ArgumentError, "Choose an active project language" unless languages.active.exists?(identifier: locale)
      raise ArgumentError, "Resolve merge conflicts before changing the source language" if catalog_drafts.where(conflict: true).exists?
      self.source_locale = locale
      [false, true].each do |pending|
        state = CatalogState.new(self, pending: pending)
        errors = state.invalid_groups.values.flatten
        state.keys.each do |key|
          next unless key.payload.kind == "scalar" && !state.plural_parent(key)
          if state.children(key.id).any?(&:text?) && !state.translation(key.id, locale)
            errors << "#{state.path(key)} needs a translation in the new source language"
          end
        end
        state.keys.select { |key| key.payload.kind == "plural" }.each do |key|
          forms = state.children(key.id).select(&:key?)
          next unless forms.any? { |form| state.children(form.id).any?(&:text?) }
          missing = plural_categories(locale).reject { |name| forms.any? { |form| form.payload.name == name && state.translation(form.id, locale) } }
          errors << "#{state.path(key)} needs source plural forms: #{missing.join(', ')}" if missing.any?
        end
        raise ArgumentError, errors.uniq.join("; ") if errors.any?
      end
      self.revision += 1
      save!
    end
  end
  has_many :project_memberships, dependent: :destroy
  has_many :users, through: :project_memberships
  has_many :project_invites, dependent: :destroy
  normalizes :name, with: ->(name) { name.strip }
  validates :slug, uniqueness: { case_sensitive: false }
  validates :name, presence: true, length: { maximum: 100 }
  validates :visibility, inclusion: { in: %w[public private] }
end
