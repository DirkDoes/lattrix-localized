class AlignLanguageSheetSelection < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE languages SET enabled = true
      WHERE project_id IS NOT NULL AND NOT enabled
        AND NOT EXISTS (SELECT 1 FROM sheet_languages WHERE language_id = languages.id AND enabled)
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
