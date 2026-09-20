class GuardOwnershipAndRetention < ActiveRecord::Migration[8.1]
  def up
    change_column_null :languages, :project_id, true
    execute <<~SQL
      CREATE FUNCTION serialize_owner_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(7142001);
        RETURN COALESCE(NEW,OLD);
      END $$;
      CREATE TRIGGER serialize_user_owner BEFORE UPDATE OR DELETE ON users FOR EACH ROW EXECUTE FUNCTION serialize_owner_mutation();
      CREATE FUNCTION guard_last_global_owner() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.role=2 AND OLD.banned_at IS NULL AND OLD.email_verified_at IS NOT NULL AND NOT EXISTS(SELECT 1 FROM users WHERE role=2 AND banned_at IS NULL AND email_verified_at IS NOT NULL) THEN
          RAISE EXCEPTION 'At least one active application owner must remain' USING ERRCODE='23514';
        END IF;
        RETURN NULL;
      END $$;
      CREATE CONSTRAINT TRIGGER last_global_owner AFTER UPDATE OR DELETE ON users DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION guard_last_global_owner();
      CREATE FUNCTION guard_project_membership() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM 1 FROM projects WHERE id=COALESCE(NEW.project_id,OLD.project_id) FOR UPDATE;
        IF TG_OP='INSERT' OR (TG_OP='UPDATE' AND NEW.project_id<>OLD.project_id) THEN
          IF (SELECT count(*) FROM project_memberships WHERE project_id=NEW.project_id)>=200 THEN RAISE EXCEPTION 'A project can have at most 200 members' USING ERRCODE='23514'; END IF;
        END IF;
        RETURN COALESCE(NEW,OLD);
      END $$;
      CREATE TRIGGER project_member_capacity BEFORE INSERT OR UPDATE OR DELETE ON project_memberships FOR EACH ROW EXECUTE FUNCTION guard_project_membership();
      CREATE FUNCTION guard_last_project_owner() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.role='owner' AND EXISTS(SELECT 1 FROM projects WHERE id=OLD.project_id) AND NOT EXISTS(SELECT 1 FROM project_memberships WHERE project_id=OLD.project_id AND role='owner') THEN
          RAISE EXCEPTION 'At least one project owner must remain' USING ERRCODE='23514';
        END IF;
        RETURN NULL;
      END $$;
      CREATE CONSTRAINT TRIGGER last_project_owner AFTER UPDATE OR DELETE ON project_memberships DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION guard_last_project_owner();
    SQL
  end
  def down
    execute "DROP FUNCTION serialize_owner_mutation() CASCADE; DROP FUNCTION guard_last_global_owner() CASCADE; DROP FUNCTION guard_project_membership() CASCADE; DROP FUNCTION guard_last_project_owner() CASCADE;"
  end
end
