class AddLanguageLifecycle < ActiveRecord::Migration[8.1]
  def change
    add_column :languages, :status, :string, null: false, default: "active"
    add_check_constraint :languages, "status IN ('active','archived','pending_deletion')", name: "language_status"
    add_index :languages, [:project_id, :status]

    reversible do |direction|
      direction.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION immutable_translation_payload() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN
            IF current_setting('app.purge_language', true)='on' THEN RETURN OLD; END IF;
            RAISE EXCEPTION 'Translation payloads are immutable' USING ERRCODE='23514';
          END $$;
        SQL
      end
      direction.down do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION immutable_translation_payload() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN RAISE EXCEPTION 'Translation payloads are immutable' USING ERRCODE='23514'; END $$;
        SQL
      end
    end
  end
end
