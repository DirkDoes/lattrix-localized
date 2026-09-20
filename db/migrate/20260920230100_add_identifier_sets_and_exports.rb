class AddIdentifierSetsAndExports < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :sheets, name: "sheet_delimiter_character"
    add_check_constraint :sheets, "char_length(delimiter) BETWEEN 1 AND 3", name: "sheet_delimiter_character"
    add_column :projects, :advanced_languages, :boolean, default: false, null: false
    create_table :identifier_sets, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.timestamps
    end
    add_index :identifier_sets, [:project_id, :name], unique: true
    create_table :language_identifiers, id: :uuid do |t|
      t.references :identifier_set, type: :uuid, null: false, foreign_key: true
      t.references :language, type: :uuid, null: false, foreign_key: true
      t.string :identifier, null: false
      t.timestamps
    end
    add_index :language_identifiers, [:identifier_set_id, :language_id], unique: true, name: :unique_language_in_identifier_set
    add_index :language_identifiers, [:identifier_set_id, :identifier], unique: true, name: :unique_identifier_in_set
    create_table :export_requests, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, foreign_key: {on_delete: :nullify}
      t.string :owner_key, null: false
      t.jsonb :options, null: false, default: {}
      t.string :status, null: false, default: "queued"
      t.integer :progress, null: false, default: 0
      t.string :filename
      t.text :error
      t.timestamps
    end
    Project.reset_column_information
    Project.find_each do |project|
      set = project.identifier_sets.create!(name: "Default")
      project.languages.find_each { |language| set.language_identifiers.create!(language: language, identifier: language.identifier) }
    end
  end
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
