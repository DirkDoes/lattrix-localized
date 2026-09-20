class SheetLanguage < ApplicationRecord
  belongs_to :sheet
  belongs_to :language
  validates :language_id, uniqueness: {scope: :sheet_id}
  validate do
    errors.add(:language, "belongs to another project") if language && sheet && language.project_id != sheet.project_id
    errors.add(:enabled, "cannot disable the default language") if !enabled && sheet&.default_language_id == language_id && !language.enabled?
  end
end
