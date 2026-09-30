class ReplaceSheetsWithCatalogs < ActiveRecord::Migration[8.1]
  def up
    # Explicitly authorized pre-launch reset. Users, identities and security settings survive.
    execute "TRUNCATE projects CASCADE"
    %w[guard_recording guard_recording_event guard_recording_identity guard_content_owner guard_retained_language guard_sheet_delimiter guard_sheet_languages guard_sheet_structure bump_translation_revision immutable_translation_payload].each do |name|
      execute "DROP FUNCTION IF EXISTS #{name}() CASCADE"
    end
    %i[recording_events recordings text_translations translation_keys translation_trees sheet_languages sheets language_identifiers identifier_sets].each { |table| drop_table table, force: :cascade }
    remove_column :projects, :advanced_languages
    add_column :projects, :source_locale, :string, null: false, default: "en"
    add_column :projects, :revision, :bigint, null: false, default: 0
    add_column :projects, :repository, :string
    add_column :projects, :installation_id, :bigint
    add_column :projects, :git_branch, :string
    add_column :projects, :locale_directory, :string, null: false, default: "config/locales"
    add_column :projects, :git_sha, :string
    add_column :projects, :sync_error, :text
    add_column :projects, :pull_request_number, :integer
    add_column :projects, :last_published_at, :datetime
    create_table :catalog_keys do |t|
      t.string :name, null: false
      t.string :kind, null: false
      t.text :description, null: false, default: ""
    end
    add_check_constraint :catalog_keys, "kind IN ('scalar','branch','plural') AND length(name)>0 AND position('.' in name)=0 AND name !~ '\\s'", name: "catalog_key_shape"
    create_table :catalog_texts do |t|
      t.string :locale, null: false
      t.text :value, null: false
    end
    create_table :catalog_nodes do |t|
      t.references :project, null: false, foreign_key: {on_delete: :cascade}
      t.references :parent, foreign_key: {to_table: :catalog_nodes}
      t.string :payload_type, null: false
      t.bigint :payload_id, null: false
      t.boolean :deleted, null: false, default: true
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :catalog_nodes, [:payload_type, :payload_id]
    create_table :catalog_change_sets do |t|
      t.references :project, null: false, foreign_key: {on_delete: :cascade}
      t.references :actor, type: :uuid, foreign_key: {to_table: :users, on_delete: :nullify}
      t.string :origin, null: false, default: "manual"
      t.string :status, null: false, default: "accepted"
      t.string :summary, null: false
      t.string :commit_sha
      t.string :github_author
      t.timestamps
    end
    create_table :catalog_events do |t|
      t.references :catalog_change_set, null: false, foreign_key: {on_delete: :cascade}
      t.references :catalog_node, null: false, foreign_key: {on_delete: :cascade}
      t.integer :sequence, null: false
      t.string :action, null: false
      t.bigint :previous_parent_id
      t.string :previous_payload_type
      t.bigint :previous_payload_id
      t.datetime :created_at, null: false
    end
    add_index :catalog_events, [:catalog_change_set_id, :sequence], unique: true
    add_check_constraint :catalog_events, "(action='payload_replaced' AND previous_payload_type IS NOT NULL AND previous_payload_id IS NOT NULL AND previous_parent_id IS NULL) OR (action='node_moved' AND previous_payload_type IS NULL AND previous_payload_id IS NULL) OR (action IN ('node_created','node_deleted','node_reactivated') AND previous_payload_type IS NULL AND previous_payload_id IS NULL AND previous_parent_id IS NULL)", name: "catalog_event_union"
    create_table :catalog_drafts do |t|
      t.references :project, null: false, foreign_key: {on_delete: :cascade}
      t.references :catalog_node, null: false, foreign_key: {on_delete: :cascade}, index: {unique: true}
      t.references :actor, type: :uuid, foreign_key: {to_table: :users, on_delete: :nullify}
      t.string :base_type, null: false
      t.bigint :base_id, null: false
      t.bigint :base_parent_id
      t.boolean :base_deleted, null: false
      t.string :payload_type, null: false
      t.bigint :payload_id, null: false
      t.bigint :parent_id
      t.boolean :deleted, null: false
      t.boolean :conflict, null: false, default: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    create_table :catalog_draft_edits do |t|
      t.references :project, null: false, foreign_key: {on_delete: :cascade}
      t.references :catalog_node, null: false, foreign_key: {on_delete: :cascade}
      t.references :actor, type: :uuid, foreign_key: {to_table: :users, on_delete: :nullify}
      t.string :previous_payload_type
      t.bigint :previous_payload_id
      t.bigint :previous_parent_id
      t.boolean :previous_deleted
      t.datetime :created_at, null: false
    end
    create_table :catalog_reviews do |t|
      t.references :catalog_node, null: false, foreign_key: {on_delete: :cascade}
      t.references :actor, type: :uuid, foreign_key: {to_table: :users, on_delete: :nullify}
      t.string :source_digest, null: false
      t.bigint :translation_payload_id, null: false
      t.timestamps
    end
    add_index :catalog_reviews, :catalog_node_id, unique: true, name: "catalog_review_node_unique"
    create_table :catalog_git_revisions do |t|
      t.references :project, null: false, foreign_key: {on_delete: :cascade}
      t.string :commit_sha, null: false
      t.string :status, null: false
      t.text :error
      t.timestamps
    end
    add_index :catalog_git_revisions, [:project_id, :commit_sha], unique: true
    create_table :catalog_tags do |t|
      t.references :project, null: false, foreign_key: {on_delete: :cascade}
      t.string :name, null: false
      t.string :commit_sha, null: false
      t.bigint :event_position, null: false
      t.datetime :created_at, null: false
    end
    add_index :catalog_tags, [:project_id, :name], unique: true
    execute <<~SQL
      CREATE FUNCTION immutable_catalog_payload() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'Catalog payloads and events are immutable'; END $$;
      CREATE TRIGGER immutable_catalog_keys BEFORE UPDATE ON catalog_keys FOR EACH ROW EXECUTE FUNCTION immutable_catalog_payload();
      CREATE TRIGGER immutable_catalog_texts BEFORE UPDATE ON catalog_texts FOR EACH ROW EXECUTE FUNCTION immutable_catalog_payload();
      CREATE TRIGGER immutable_catalog_events BEFORE UPDATE ON catalog_events FOR EACH ROW EXECUTE FUNCTION immutable_catalog_payload();
      CREATE FUNCTION guard_catalog_node() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE p catalog_nodes;
      BEGIN
        PERFORM 1 FROM projects WHERE id=NEW.project_id FOR UPDATE;
        IF NEW.payload_type NOT IN ('CatalogKey','CatalogText') THEN RAISE EXCEPTION 'Invalid payload type'; END IF;
        IF NEW.payload_type='CatalogKey' AND NOT EXISTS(SELECT 1 FROM catalog_keys WHERE id=NEW.payload_id) THEN RAISE EXCEPTION 'Missing key payload'; END IF;
        IF NEW.payload_type='CatalogText' AND NOT EXISTS(SELECT 1 FROM catalog_texts WHERE id=NEW.payload_id) THEN RAISE EXCEPTION 'Missing text payload'; END IF;
        IF NEW.parent_id IS NOT NULL THEN
          SELECT * INTO STRICT p FROM catalog_nodes WHERE id=NEW.parent_id;
          IF p.project_id<>NEW.project_id OR p.payload_type<>'CatalogKey' THEN RAISE EXCEPTION 'Invalid catalog parent'; END IF;
          IF EXISTS(WITH RECURSIVE a AS (SELECT id,parent_id FROM catalog_nodes WHERE id=NEW.parent_id UNION SELECT n.id,n.parent_id FROM catalog_nodes n JOIN a ON n.id=a.parent_id) SELECT 1 FROM a WHERE id=NEW.id) THEN RAISE EXCEPTION 'Catalog cycle'; END IF;
        ELSIF NEW.payload_type='CatalogText' THEN RAISE EXCEPTION 'Translation needs a key'; END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER catalog_node_integrity BEFORE INSERT OR UPDATE ON catalog_nodes FOR EACH ROW EXECUTE FUNCTION guard_catalog_node();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Pre-launch catalog reset has no data-preserving rollback"
  end
end
