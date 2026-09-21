class CreateRecordingEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_events do |t|
      t.references :recording, null: false, foreign_key: {on_delete: :cascade}
      t.references :actor, type: :uuid, foreign_key: {to_table: :users, on_delete: :nullify}
      t.string :action, null: false
      t.string :recordable_type, null: false
      t.bigint :recordable_id, null: false
      t.datetime :deleted_at
      t.boolean :reverted, null: false, default: false
      t.datetime :created_at, null: false
    end

    add_index :recording_events, [:recording_id, :id]
    add_index :recording_events, [:recordable_type, :recordable_id]
    add_check_constraint :recording_events, "action IN ('created','updated','deleted')", name: "recording_event_action"
    add_check_constraint :recording_events, "(action = 'deleted') = (deleted_at IS NOT NULL)", name: "recording_event_deletion"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE FUNCTION guard_recording_identity() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF NEW.translation_tree_id<>OLD.translation_tree_id OR NEW.parent_id IS DISTINCT FROM OLD.parent_id THEN
              RAISE EXCEPTION 'Moving recordings is not supported' USING ERRCODE='23514';
            END IF;
            RETURN NEW;
          END $$;
          CREATE TRIGGER recording_identity BEFORE UPDATE ON recordings FOR EACH ROW EXECUTE FUNCTION guard_recording_identity();

          CREATE FUNCTION guard_recording_event() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF NEW.recordable_type='TranslationKey' AND NOT EXISTS(SELECT 1 FROM translation_keys WHERE id=NEW.recordable_id) THEN
              RAISE EXCEPTION 'History key payload does not exist' USING ERRCODE='23503';
            ELSIF NEW.recordable_type='TextTranslation' AND NOT EXISTS(SELECT 1 FROM text_translations WHERE id=NEW.recordable_id) THEN
              RAISE EXCEPTION 'History translation payload does not exist' USING ERRCODE='23503';
            ELSIF NEW.recordable_type NOT IN ('TranslationKey','TextTranslation') THEN
              RAISE EXCEPTION 'Unsupported history payload type' USING ERRCODE='23514';
            END IF;
            RETURN NEW;
          END $$;
          CREATE TRIGGER recording_event_integrity BEFORE INSERT ON recording_events FOR EACH ROW EXECUTE FUNCTION guard_recording_event();
        SQL
      end
      direction.down do
        execute "DROP FUNCTION guard_recording_event() CASCADE"
        execute "DROP FUNCTION guard_recording_identity() CASCADE"
      end
    end
  end
end
