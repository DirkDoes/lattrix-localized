class CompletePluralCategories < ActiveRecord::Migration[8.1]
  def up
    Sheet.update_all(plural_categories: TranslationKey::PLURAL_CATEGORIES)
    Recording.active.keys.joins("JOIN translation_keys k ON k.id=recordings.recordable_id JOIN translation_trees t ON t.id=recordings.translation_tree_id JOIN sheets s ON s.id=t.sheet_id").where("k.pluralized AND s.pluralization_enabled").find_each do |key|
      begin
        key.set_pluralized!(true)
      rescue ArgumentError => error
        # Preserve both sides of legacy conversion conflicts instead of choosing a value.
        key.set_pluralized!(false)
        say "Kept key #{key.id} as an ordinary key: #{error.message}"
      end
    end
  end

  def down
    # Retain the category keys and all their translations.
  end
end
