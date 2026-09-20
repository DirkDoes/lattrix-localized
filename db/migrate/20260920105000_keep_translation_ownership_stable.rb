class KeepTranslationOwnershipStable < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE FUNCTION guard_content_owner() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF TG_TABLE_NAME='translation_trees' THEN
          IF NEW.sheet_id<>OLD.sheet_id THEN RAISE EXCEPTION 'Moving trees across sheets is not supported' USING ERRCODE='23514'; END IF;
        ELSIF TG_TABLE_NAME='project_memberships' THEN
          IF NEW.project_id<>OLD.project_id THEN RAISE EXCEPTION 'Moving memberships across projects is not supported' USING ERRCODE='23514'; END IF;
        ELSE
          IF NEW.project_id IS NOT NULL AND NEW.project_id IS DISTINCT FROM OLD.project_id THEN RAISE EXCEPTION 'Moving languages across projects is not supported' USING ERRCODE='23514'; END IF;
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER tree_owner BEFORE UPDATE ON translation_trees FOR EACH ROW EXECUTE FUNCTION guard_content_owner();
      CREATE TRIGGER membership_owner BEFORE UPDATE ON project_memberships FOR EACH ROW EXECUTE FUNCTION guard_content_owner();
      CREATE TRIGGER language_owner BEFORE UPDATE ON languages FOR EACH ROW EXECUTE FUNCTION guard_content_owner();
      CREATE FUNCTION guard_retained_language() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.project_id IS NULL AND EXISTS(SELECT 1 FROM projects WHERE id=OLD.project_id) THEN RAISE EXCEPTION 'A language can only be archived when its project is deleted' USING ERRCODE='23514'; END IF;
        RETURN NULL;
      END $$;
      CREATE CONSTRAINT TRIGGER retained_language AFTER UPDATE ON languages DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION guard_retained_language();
      CREATE OR REPLACE FUNCTION serialize_owner_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        -- Only owner mutations contend; ordinary profile edits do not take this lock.
        IF OLD.role=2 OR (TG_OP='UPDATE' AND NEW.role=2) THEN PERFORM pg_advisory_xact_lock(7142001); END IF;
        RETURN COALESCE(NEW,OLD);
      END $$;
    SQL
  end
  def down
    execute "DROP FUNCTION guard_content_owner() CASCADE; DROP FUNCTION guard_retained_language() CASCADE;"
  end
end
