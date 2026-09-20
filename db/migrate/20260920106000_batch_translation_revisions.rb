class BatchTranslationRevisions < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      DROP TRIGGER recording_revision ON recordings;
      CREATE OR REPLACE FUNCTION bump_translation_revision() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        UPDATE translation_trees SET revision=revision+1,updated_at=NOW() WHERE id IN (SELECT DISTINCT translation_tree_id FROM changed_records);
        RETURN NULL;
      END $$;
      CREATE TRIGGER recording_insert_revision AFTER INSERT ON recordings REFERENCING NEW TABLE AS changed_records FOR EACH STATEMENT EXECUTE FUNCTION bump_translation_revision();
      CREATE TRIGGER recording_update_revision AFTER UPDATE ON recordings REFERENCING NEW TABLE AS changed_records FOR EACH STATEMENT EXECUTE FUNCTION bump_translation_revision();
      CREATE TRIGGER recording_delete_revision AFTER DELETE ON recordings REFERENCING OLD TABLE AS changed_records FOR EACH STATEMENT EXECUTE FUNCTION bump_translation_revision();
    SQL
  end
  def down
    execute <<~SQL
      DROP TRIGGER recording_insert_revision ON recordings;
      DROP TRIGGER recording_update_revision ON recordings;
      DROP TRIGGER recording_delete_revision ON recordings;
      CREATE OR REPLACE FUNCTION bump_translation_revision() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        UPDATE translation_trees SET revision=revision+1,updated_at=NOW() WHERE id=COALESCE(NEW.translation_tree_id,OLD.translation_tree_id);
        RETURN NULL;
      END $$;
      CREATE TRIGGER recording_revision AFTER INSERT OR UPDATE OR DELETE ON recordings FOR EACH ROW EXECUTE FUNCTION bump_translation_revision();
    SQL
  end
end
