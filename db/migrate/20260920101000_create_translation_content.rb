class CreateTranslationContent < ActiveRecord::Migration[8.1]
  def change
    create_table :languages, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.string :identifier, null: false
      t.boolean :enabled, default: false, null: false
      t.timestamps
    end
    add_index :languages, [:project_id, :identifier], unique: true
    add_check_constraint :languages, "length(name) > 0 AND identifier ~ '^[a-z0-9]+([-_][a-z0-9]+)*$'", name: "language_identity"
    create_table :sheet_languages, id: :uuid do |t|
      t.references :sheet, type: :uuid, null: false, foreign_key: true
      t.references :language, type: :uuid, null: false, foreign_key: true
      t.boolean :enabled, default: true, null: false
    end
    add_index :sheet_languages, [:sheet_id, :language_id], unique: true
    create_table :membership_languages, id: :uuid do |t|
      t.references :project_membership, type: :uuid, null: false, foreign_key: true
      t.references :language, type: :uuid, null: false, foreign_key: true
    end
    add_index :membership_languages, [:project_membership_id, :language_id], unique: true, name: "membership_language_unique"
    add_reference :sheets, :default_language, type: :uuid, foreign_key: {to_table: :languages}
    add_column :sheets, :case_sensitive_keys, :boolean, default: false, null: false
    add_column :sheets, :allow_parent_translations, :boolean, default: true, null: false
    add_column :sheets, :pluralization_enabled, :boolean, default: true, null: false
    add_column :sheets, :plural_categories, :string, array: true, default: %w[zero one two few many other], null: false
    add_column :sheets, :missing_value_behavior, :string, default: "omit", null: false
    add_check_constraint :sheets, "missing_value_behavior IN ('omit','empty','fallback')", name: "sheet_missing_values"
    create_table :translation_trees, id: :uuid do |t|
      t.references :sheet, type: :uuid, null: false, foreign_key: true, index: {unique: true}
      t.string :name, default: "main", null: false
      t.bigint :revision, default: 0, null: false
      t.timestamps
    end
    create_table :translation_keys, id: :uuid do |t|
      t.string :name, null: false
      t.boolean :pluralized, default: false, null: false
      t.timestamps
    end
    add_check_constraint :translation_keys, "length(name) BETWEEN 1 AND 200", name: "key_name_length"
    create_table :text_translations, id: :uuid do |t|
      t.references :language, type: :uuid, null: false, foreign_key: true
      t.text :text, null: false
      t.timestamps
    end
    add_check_constraint :text_translations, "length(text) > 0", name: "translation_nonempty"
    create_table :recordings, id: :uuid do |t|
      t.references :translation_tree, type: :uuid, null: false, foreign_key: true
      t.references :parent, type: :uuid, foreign_key: {to_table: :recordings}
      t.string :recordable_type, null: false
      t.uuid :recordable_id, null: false
      t.integer :lock_version, default: 0, null: false
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :recordings, [:recordable_type, :recordable_id]
    add_index :recordings, [:translation_tree_id, :parent_id], where: "deleted_at IS NULL", name: "active_tree_children"
    add_check_constraint :recordings, "recordable_type IN ('TranslationKey','TextTranslation') AND (parent_id IS NULL OR parent_id <> id)", name: "recording_type_parent"
    reversible do |dir|
      dir.up { execute "INSERT INTO translation_trees (id, sheet_id, name, revision, created_at, updated_at) SELECT gen_random_uuid(), id, 'main', 0, NOW(), NOW() FROM sheets" }
    end
  end
end
