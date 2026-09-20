class RefineTranslationKeys < ActiveRecord::Migration[8.1]
  def change
    add_column :translation_keys, :description, :text, null: false, default: ""
    change_column_null :sheets, :default_language_id, true
  end
end
