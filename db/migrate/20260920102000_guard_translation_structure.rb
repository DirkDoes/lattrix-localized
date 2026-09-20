class GuardTranslationStructure < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION immutable_translation_payload() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'Translation payloads are immutable' USING ERRCODE='23514'; END $$;
      CREATE TRIGGER immutable_key BEFORE UPDATE OR DELETE ON translation_keys FOR EACH ROW EXECUTE FUNCTION immutable_translation_payload();
      CREATE TRIGGER immutable_text BEFORE UPDATE OR DELETE ON text_translations FOR EACH ROW EXECUTE FUNCTION immutable_translation_payload();

      CREATE FUNCTION guard_recording() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE owner_sheet sheets; parent_record recordings; key_name text; lang uuid;
      BEGIN
        -- Serialize structural checks within one tree, including raw SQL writes.
        PERFORM 1 FROM translation_trees WHERE id=NEW.translation_tree_id FOR UPDATE;
        SELECT s.* INTO STRICT owner_sheet FROM sheets s JOIN translation_trees t ON t.sheet_id=s.id WHERE t.id=NEW.translation_tree_id;
        IF TG_OP='UPDATE' AND NEW.translation_tree_id<>OLD.translation_tree_id THEN RAISE EXCEPTION 'Moving across trees is not supported' USING ERRCODE='23514'; END IF;
        IF NEW.parent_id IS NOT NULL THEN
          SELECT * INTO STRICT parent_record FROM recordings WHERE id=NEW.parent_id;
          IF parent_record.translation_tree_id<>NEW.translation_tree_id OR parent_record.recordable_type<>'TranslationKey' THEN RAISE EXCEPTION 'Invalid parent' USING ERRCODE='23514'; END IF;
          IF NEW.deleted_at IS NULL AND parent_record.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'Parent is deleted' USING ERRCODE='23514'; END IF;
          IF EXISTS(WITH RECURSIVE ancestors AS (
            SELECT id,parent_id FROM recordings WHERE id=NEW.parent_id
            UNION SELECT r.id,r.parent_id FROM recordings r JOIN ancestors a ON r.id=a.parent_id
          ) SELECT 1 FROM ancestors WHERE id=NEW.id) THEN RAISE EXCEPTION 'Tree cycle' USING ERRCODE='23514'; END IF;
        ELSIF NEW.recordable_type<>'TranslationKey' THEN RAISE EXCEPTION 'A translation needs a key' USING ERRCODE='23514'; END IF;
        IF TG_OP='UPDATE' AND NEW.recordable_type<>OLD.recordable_type THEN RAISE EXCEPTION 'Recording type cannot change' USING ERRCODE='23514'; END IF;
        IF NEW.recordable_type='TranslationKey' THEN
          SELECT name INTO STRICT key_name FROM translation_keys WHERE id=NEW.recordable_id;
          IF NEW.deleted_at IS NULL AND EXISTS(SELECT 1 FROM recordings r JOIN translation_keys k ON k.id=r.recordable_id
            WHERE r.translation_tree_id=NEW.translation_tree_id AND r.parent_id IS NOT DISTINCT FROM NEW.parent_id
            AND r.recordable_type='TranslationKey' AND r.deleted_at IS NULL AND r.id<>NEW.id
            AND CASE WHEN owner_sheet.case_sensitive_keys THEN k.name=key_name ELSE lower(k.name)=lower(key_name) END)
          THEN RAISE EXCEPTION 'A key with this name already exists under this parent' USING ERRCODE='23514'; END IF;
        ELSE
          SELECT language_id INTO STRICT lang FROM text_translations WHERE id=NEW.recordable_id;
          IF NOT EXISTS(SELECT 1 FROM languages WHERE id=lang AND project_id=owner_sheet.project_id) THEN RAISE EXCEPTION 'Language belongs to another project' USING ERRCODE='23514'; END IF;
          IF NEW.deleted_at IS NULL AND EXISTS(SELECT 1 FROM recordings r JOIN text_translations v ON v.id=r.recordable_id
            WHERE r.parent_id=NEW.parent_id AND r.recordable_type='TextTranslation' AND r.deleted_at IS NULL AND r.id<>NEW.id AND v.language_id=lang)
          THEN RAISE EXCEPTION 'This key already has a translation in this language' USING ERRCODE='23514'; END IF;
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER recording_integrity BEFORE INSERT OR UPDATE ON recordings FOR EACH ROW EXECUTE FUNCTION guard_recording();
      CREATE FUNCTION bump_translation_revision() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        UPDATE translation_trees SET revision=revision+1,updated_at=NOW() WHERE id=COALESCE(NEW.translation_tree_id,OLD.translation_tree_id);
        RETURN NULL;
      END $$;
      CREATE TRIGGER recording_revision AFTER INSERT OR UPDATE OR DELETE ON recordings FOR EACH ROW EXECUTE FUNCTION bump_translation_revision();
      CREATE FUNCTION guard_sheet_languages() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE project uuid;
      BEGIN
        IF TG_TABLE_NAME='sheet_languages' THEN SELECT project_id INTO project FROM sheets WHERE id=NEW.sheet_id;
        ELSE SELECT project_id INTO project FROM project_memberships WHERE id=NEW.project_membership_id; END IF;
        IF NOT EXISTS(SELECT 1 FROM languages WHERE id=NEW.language_id AND project_id=project) THEN RAISE EXCEPTION 'Language belongs to another project' USING ERRCODE='23514'; END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER sheet_language_integrity BEFORE INSERT OR UPDATE ON sheet_languages FOR EACH ROW EXECUTE FUNCTION guard_sheet_languages();
      CREATE TRIGGER membership_language_integrity BEFORE INSERT OR UPDATE ON membership_languages FOR EACH ROW EXECUTE FUNCTION guard_sheet_languages();
      CREATE FUNCTION guard_sheet_structure() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM 1 FROM projects WHERE id=NEW.project_id FOR UPDATE;
        IF TG_OP='INSERT' AND (SELECT count(*) FROM sheets WHERE project_id=NEW.project_id)>=90 THEN RAISE EXCEPTION 'A project can contain at most 90 sheets' USING ERRCODE='23514'; END IF;
        IF NEW.default_language_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM languages WHERE id=NEW.default_language_id AND project_id=NEW.project_id) THEN RAISE EXCEPTION 'Default language belongs to another project' USING ERRCODE='23514'; END IF;
        IF TG_OP='UPDATE' THEN
          IF NEW.project_id<>OLD.project_id THEN RAISE EXCEPTION 'Moving sheets across projects is not supported' USING ERRCODE='23514'; END IF;
          PERFORM 1 FROM translation_trees WHERE sheet_id=NEW.id FOR UPDATE;
          IF NOT NEW.case_sensitive_keys AND EXISTS(SELECT 1 FROM recordings r JOIN translation_keys k ON k.id=r.recordable_id JOIN translation_trees t ON t.id=r.translation_tree_id
            WHERE t.sheet_id=NEW.id AND r.recordable_type='TranslationKey' AND r.deleted_at IS NULL
            GROUP BY r.translation_tree_id,r.parent_id,lower(k.name) HAVING count(*)>1)
          THEN RAISE EXCEPTION 'Resolve case-conflicting keys before disabling case sensitivity' USING ERRCODE='23514'; END IF;
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER sheet_integrity BEFORE INSERT OR UPDATE ON sheets FOR EACH ROW EXECUTE FUNCTION guard_sheet_structure();
    SQL
  end
  def down
    execute "DROP FUNCTION guard_sheet_structure() CASCADE; DROP FUNCTION guard_sheet_languages() CASCADE; DROP FUNCTION bump_translation_revision() CASCADE; DROP FUNCTION guard_recording() CASCADE; DROP FUNCTION immutable_translation_payload() CASCADE;"
  end
end
