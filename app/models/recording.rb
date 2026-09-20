class Recording < ApplicationRecord
  belongs_to :translation_tree
  belongs_to :parent, class_name: "Recording", optional: true
  has_many :children, class_name: "Recording", foreign_key: :parent_id
  delegated_type :recordable, types: %w[TranslationKey TextTranslation]
  scope :active, -> { where(deleted_at: nil) }
  scope :keys, -> { where(recordable_type: "TranslationKey") }
  scope :texts, -> { where(recordable_type: "TextTranslation") }
  delegate :sheet, to: :translation_tree

  def self.create_key!(tree:, parent:, name:, values: {}, description: "")
    tree.with_lock do
      tree.sheet.reload
      raise ArgumentError, "Plural category keys cannot contain child keys" if parent&.plural_category?
      if parent && !tree.sheet.allow_parent_translations? && parent.children.active.texts.exists?
        raise ArgumentError, "This parent has translations. Move or remove them before adding children."
      end
      key = create!(translation_tree: tree, parent: parent, recordable: TranslationKey.create!(name: name, description: description))
      values.each { |language, text| key.save_translation!(language, text) unless text.empty? }
      key
    end
  end

  def save_translation!(language, text, expected: nil, existing_id: nil)
    translation_tree.with_lock do
      sheet.reload
      raise ArgumentError, "Key was deleted" if reload.deleted_at
      raise ArgumentError, "Translate the plural categories instead" if sheet.pluralization_enabled? && recordable.pluralized
      raise ArgumentError, "Language is not enabled" unless sheet.active_languages.exists?(id: language.id)
      if !sheet.allow_parent_translations? && children.active.keys.exists?
        raise ArgumentError, "This key has nested keys and parent translations are disabled"
      end
      current = children.active.texts.joins("JOIN text_translations ON text_translations.id=recordings.recordable_id").find_by(text_translations: {language_id: language.id})
      if expected
        unless current&.id.to_s == existing_id.to_s && (current ? current.lock_version.to_s == expected.to_s : expected.to_s == "new")
          raise ActiveRecord::StaleObjectError.new(current || self, "update")
        end
      end
      if text.empty?
        current&.update!(deleted_at: Time.current)
        return nil
      end
      return current if current && current.recordable.text == text
      payload = TextTranslation.create!(language: language, text: text)
      current ? current.update!(recordable: payload) : current = children.create!(translation_tree: translation_tree, recordable: payload)
      current
    end
  end

  def change_key!(name:, parent_id:, expected:, description: recordable.description)
    translation_tree.with_lock do
      reload
      sheet.reload
      raise ArgumentError, "Key was deleted" if deleted_at
      raise ActiveRecord::StaleObjectError.new(self, "update") unless lock_version == expected.to_i
      raise ArgumentError, "Edit plural categories through their parent" if plural_category?
      target = parent_id.present? ? translation_tree.recordings.active.keys.find(parent_id) : nil
      raise ArgumentError, "Plural category keys cannot contain child keys" if target&.plural_category?
      if target && !sheet.allow_parent_translations? && target.children.active.texts.exists?
        raise ArgumentError, "The selected parent has translations"
      end
      update!(parent: target, recordable: TranslationKey.create!(name: name, description: description, pluralized: recordable.pluralized))
    end
  end

  def discard_subtree!(expected:)
    translation_tree.with_lock do
      reload
      sheet.reload
      raise ArgumentError, "Key was deleted" if deleted_at
      raise ActiveRecord::StaleObjectError.new(self, "delete") unless lock_version == expected.to_i
      raise ArgumentError, "Remove plural categories through their parent" if plural_category?
      self.class.connection.execute(<<~SQL)
        WITH RECURSIVE subtree AS (SELECT id FROM recordings WHERE id=#{self.class.connection.quote(id)} UNION ALL SELECT r.id FROM recordings r JOIN subtree s ON r.parent_id=s.id)
        UPDATE recordings SET deleted_at=NOW(),updated_at=NOW(),lock_version=lock_version+1 WHERE id IN(SELECT id FROM subtree) AND deleted_at IS NULL
      SQL
    end
  end

  def plural_category?
    sheet.pluralization_enabled? && parent&.recordable&.pluralized && TranslationKey::PLURAL_CATEGORIES.include?(recordable.name)
  end

  def set_pluralized!(enabled)
    translation_tree.with_lock do
      reload
      raise ArgumentError, "Edit pluralization through the parent key" if plural_category?
      raise ArgumentError, "Plural editor is disabled" if enabled && !sheet.pluralization_enabled?
      if enabled
        forms = children.active.keys.includes(:recordable).index_by { |child| child.recordable.name }
        raise ArgumentError, "Plural category keys cannot contain nested keys" if forms.values.any? { |form| TranslationKey::PLURAL_CATEGORIES.include?(form.recordable.name) && form.children.active.keys.exists? }
        values = children.active.texts.includes(:recordable).to_a
        other = forms["other"]
        values.each do |value|
          existing = other&.children&.active&.texts&.includes(:recordable)&.find { |v| v.recordable.language_id == value.recordable.language_id }
          if existing && existing.recordable.text != value.recordable.text
            raise ArgumentError, "The parent and other have different translations. Resolve those values before enabling plurals."
          end
        end
        # Move existing values before adding children so parent-translation restrictions still hold.
        values.each { |value| value.update!(deleted_at: Time.current) }
        TranslationKey::PLURAL_CATEGORIES.each do |name|
          forms[name] ||= self.class.create_key!(tree: translation_tree, parent: self, name: name)
        end
        values.each { |value| forms.fetch("other").save_translation!(value.recordable.language, value.recordable.text) }
      end
      update!(recordable: TranslationKey.create!(name: recordable.name, description: recordable.description, pluralized: enabled)) if recordable.pluralized != enabled
    end
  end
end
