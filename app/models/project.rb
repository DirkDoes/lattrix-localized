class Project < ApplicationRecord
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
  def writable? = sync_error.blank?
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
          missing = CatalogLocale.categories(locale).reject { |name| forms.any? { |form| form.payload.name == name && state.translation(form.id, locale) } }
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
