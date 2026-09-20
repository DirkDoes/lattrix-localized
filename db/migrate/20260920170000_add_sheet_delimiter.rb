class AddSheetDelimiter < ActiveRecord::Migration[8.1]
  def up
    add_column :sheets, :delimiter, :string, null: false, default: "."
    add_check_constraint :sheets, "char_length(delimiter) = 1", name: "sheet_delimiter_character"
    execute <<~SQL
      CREATE FUNCTION guard_sheet_delimiter() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE separator text;
      BEGIN
        IF TG_TABLE_NAME='sheets' THEN
          IF NEW.delimiter IS DISTINCT FROM OLD.delimiter AND EXISTS(
            SELECT 1 FROM recordings r JOIN translation_trees t ON t.id=r.translation_tree_id JOIN translation_keys k ON k.id=r.recordable_id
            WHERE t.sheet_id=NEW.id AND r.recordable_type='TranslationKey' AND r.deleted_at IS NULL AND position(NEW.delimiter in k.name)>0
          ) THEN RAISE EXCEPTION 'Cannot change delimiter: existing keys contain this character. Rename them first.' USING ERRCODE='23514'; END IF;
        ELSIF NEW.recordable_type='TranslationKey' AND NEW.deleted_at IS NULL THEN
          SELECT s.delimiter INTO separator FROM sheets s JOIN translation_trees t ON t.sheet_id=s.id WHERE t.id=NEW.translation_tree_id;
          IF EXISTS(SELECT 1 FROM translation_keys WHERE id=NEW.recordable_id AND position(separator in name)>0) THEN
            RAISE EXCEPTION 'A key name cannot contain the sheet delimiter' USING ERRCODE='23514';
          END IF;
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER zz_sheet_delimiter BEFORE UPDATE ON sheets FOR EACH ROW EXECUTE FUNCTION guard_sheet_delimiter();
      CREATE TRIGGER zz_recording_delimiter BEFORE INSERT OR UPDATE ON recordings FOR EACH ROW EXECUTE FUNCTION guard_sheet_delimiter();
    SQL
  end
  def down
    execute "DROP TRIGGER zz_sheet_delimiter ON sheets; DROP TRIGGER zz_recording_delimiter ON recordings; DROP FUNCTION guard_sheet_delimiter();"
    remove_check_constraint :sheets, name: "sheet_delimiter_character"
    remove_column :sheets, :delimiter
  end
end
