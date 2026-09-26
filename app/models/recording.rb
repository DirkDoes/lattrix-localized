class Recording < ApplicationRecord
  belongs_to :translation_tree
  belongs_to :parent, class_name: "Recording", optional: true
  has_many :children, class_name: "Recording", foreign_key: :parent_id
  has_many :recording_events, dependent: :delete_all
  delegated_type :recordable, types: %w[TranslationKey TextTranslation]
  scope :active, -> { where(deleted_at: nil) }
  scope :keys, -> { where(recordable_type: "TranslationKey") }
  scope :texts, -> { where(recordable_type: "TextTranslation") }
  delegate :sheet, to: :translation_tree

  def self.descendants_first(rows)
    by_id = rows.index_by(&:id)
    depths = {}
    depth = ->(row) { depths[row.id] ||= by_id[row.parent_id] ? depth.call(by_id.fetch(row.parent_id)) + 1 : 0 }
    rows.sort_by { |row| [ -depth.call(row), row.id ] }
  end

  def self.create_key!(tree:, parent:, name:, values: {}, description: "", actor: nil)
    tree.with_lock do
      tree.sheet.reload
      raise ArgumentError, "Plural category keys cannot contain child keys" if parent&.plural_category?
      if parent && !tree.sheet.allow_parent_translations? && parent.children.active.texts.exists?
        raise ArgumentError, "This parent has translations. Move or remove them before adding children."
      end
      key = create!(translation_tree: tree, parent: parent, recordable: TranslationKey.create!(name: name, description: description))
      key.record_event!("created", actor: actor)
      values.each { |language, text| key.save_translation!(language, text, actor: actor) unless text.empty? }
      key
    end
  end

  def save_translation!(language, text, expected: nil, existing_id: nil, actor: nil)
    translation_tree.with_lock do
      sheet.reload
      raise ArgumentError, "Key was deleted" if reload.deleted_at
      raise ArgumentError, "Translate the plural categories instead" if sheet.pluralization_enabled? && recordable.pluralized
      raise ArgumentError, "Language is not enabled" unless sheet.active_languages.exists?(id: language.id)
      if !sheet.allow_parent_translations? && children.active.keys.exists?
        raise ArgumentError, "This key has nested keys and parent translations are disabled"
      end
      current = children.active.texts.joins("JOIN text_translations ON text_translations.id=recordings.recordable_id").find_by(text_translations: { language_id: language.id })
      if expected
        unless current&.id.to_s == existing_id.to_s && (current ? current.lock_version.to_s == expected.to_s : expected.to_s == "new")
          raise ActiveRecord::StaleObjectError.new(current || self, "update")
        end
      end
      if text.empty?
        if current
          current.update!(deleted_at: Time.current)
          current.record_event!("deleted", actor: actor)
        end
        return nil
      end
      return current if current && current.recordable.text == text
      payload = TextTranslation.create!(language: language, text: text)
      if current
        current.update!(recordable: payload)
        current.record_event!("updated", actor: actor)
      else
        current = children.create!(translation_tree: translation_tree, recordable: payload)
        current.record_event!("created", actor: actor)
      end
      current
    end
  end

  def change_key!(name:, parent_id:, expected:, description: recordable.description, actor: nil)
    translation_tree.with_lock do
      reload
      sheet.reload
      raise ArgumentError, "Key was deleted" if deleted_at
      raise ActiveRecord::StaleObjectError.new(self, "update") unless lock_version == expected.to_i
      raise ArgumentError, "Edit plural categories through their parent" if plural_category?
      raise ArgumentError, "Moving keys is not supported" unless parent_id.to_s == parent_id_in_database.to_s
      target = parent_id.present? ? translation_tree.recordings.active.keys.find(parent_id) : nil
      raise ArgumentError, "Plural category keys cannot contain child keys" if target&.plural_category?
      if target && !sheet.allow_parent_translations? && target.children.active.texts.exists?
        raise ArgumentError, "The selected parent has translations"
      end
      update!(parent: target, recordable: TranslationKey.create!(name: name, description: description, pluralized: recordable.pluralized))
      record_event!("updated", actor: actor)
    end
  end

  def discard_subtree!(expected:, actor: nil)
    translation_tree.with_lock do
      reload
      sheet.reload
      raise ArgumentError, "Key was deleted" if deleted_at
      raise ActiveRecord::StaleObjectError.new(self, "delete") unless lock_version == expected.to_i
      raise ArgumentError, "Remove plural categories through their parent" if plural_category?
      ids = self.class.connection.select_values(<<~SQL)
        WITH RECURSIVE subtree AS (SELECT id FROM recordings WHERE id=#{self.class.connection.quote(id)} UNION ALL SELECT r.id FROM recordings r JOIN subtree s ON r.parent_id=s.id)
        SELECT id FROM subtree
      SQL
      removed_at = Time.current
      rows = self.class.descendants_first(self.class.where(id: ids, deleted_at: nil).to_a)
      self.class.where(id: rows.map(&:id)).update_all(deleted_at: removed_at, updated_at: removed_at, lock_version: Arel.sql("lock_version+1"))
      RecordingEvent.insert_all!(rows.map { |row| { recording_id: row.id, actor_id: actor&.id, action: "deleted", recordable_type: row.recordable_type, recordable_id: row.recordable_id, deleted_at: removed_at, change_type: "manual", created_at: removed_at } }) if rows.any?
    end
  end

  def record_event!(action, actor:, change_type: "manual", created_at: nil, change_id: nil)
    attributes = { actor: actor, action: action, recordable_type: recordable_type, recordable_id: recordable_id, deleted_at: deleted_at, change_type: change_type }
    attributes[:created_at] = created_at if created_at
    attributes[:change_id] = change_id if change_id
    recording_events.create!(attributes)
  end

  def plural_category?
    sheet.pluralization_enabled? && parent&.recordable&.pluralized && TranslationKey::PLURAL_CATEGORIES.include?(recordable.name)
  end

  def set_pluralized!(enabled, actor: nil)
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
        values.each do |value|
          value.update!(deleted_at: Time.current)
          value.record_event!("deleted", actor: actor)
        end
        TranslationKey::PLURAL_CATEGORIES.each do |name|
          forms[name] ||= self.class.create_key!(tree: translation_tree, parent: self, name: name, actor: actor)
        end
        values.each { |value| forms.fetch("other").save_translation!(value.recordable.language, value.recordable.text, actor: actor) }
      else
        forms = children.active.keys.includes(:recordable).index_by { |child| child.recordable.name }
        (TranslationKey::PLURAL_CATEGORIES - %w[one other]).filter_map { |name| forms[name] }.reject { |form| form.children.active.texts.exists? }.each do |form|
          removed_at = Time.current
          form.update!(deleted_at: removed_at)
          form.record_event!("deleted", actor: actor, created_at: removed_at)
        end
      end
      if recordable.pluralized != enabled
        update!(recordable: TranslationKey.create!(name: recordable.name, description: recordable.description, pluralized: enabled))
        record_event!("updated", actor: actor)
      end
    end
  end
end
