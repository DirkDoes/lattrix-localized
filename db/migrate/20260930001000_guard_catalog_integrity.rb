class GuardCatalogIntegrity < ActiveRecord::Migration[8.1]
  def up
    drop_table :export_requests, if_exists: true, force: :cascade
    execute <<~SQL
      CREATE FUNCTION guard_catalog_event() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE node_project bigint; change_project bigint;
      BEGIN
        SELECT project_id INTO STRICT node_project FROM catalog_nodes WHERE id=NEW.catalog_node_id;
        SELECT project_id INTO STRICT change_project FROM catalog_change_sets WHERE id=NEW.catalog_change_set_id;
        IF node_project<>change_project THEN RAISE EXCEPTION 'Event crosses projects'; END IF;
        IF NEW.previous_parent_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM catalog_nodes WHERE id=NEW.previous_parent_id AND project_id=node_project) THEN RAISE EXCEPTION 'Invalid prior parent'; END IF;
        IF NEW.action='payload_replaced' THEN
          IF NOT ((NEW.previous_payload_type='CatalogKey' AND EXISTS(SELECT 1 FROM catalog_keys WHERE id=NEW.previous_payload_id)) OR (NEW.previous_payload_type='CatalogText' AND EXISTS(SELECT 1 FROM catalog_texts WHERE id=NEW.previous_payload_id))) THEN RAISE EXCEPTION 'Invalid prior payload'; END IF;
        END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER catalog_event_integrity BEFORE INSERT ON catalog_events FOR EACH ROW EXECUTE FUNCTION guard_catalog_event();
      CREATE FUNCTION guard_catalog_shape() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM catalog_nodes n JOIN catalog_nodes p ON p.id=n.parent_id
          JOIN catalog_keys k ON p.payload_type='CatalogKey' AND k.id=p.payload_id
          WHERE n.project_id=NEW.project_id AND NOT n.deleted AND
            (p.deleted OR (n.payload_type='CatalogText' AND k.kind<>'scalar') OR (n.payload_type='CatalogKey' AND k.kind='scalar'))
        ) THEN RAISE EXCEPTION 'Invalid active catalog hierarchy'; END IF;
        IF EXISTS (
          SELECT 1 FROM catalog_nodes n JOIN catalog_keys k ON n.payload_type='CatalogKey' AND k.id=n.payload_id
          WHERE n.project_id=NEW.project_id AND NOT n.deleted
          GROUP BY n.parent_id,k.name HAVING count(*)>1
        ) THEN RAISE EXCEPTION 'Duplicate active key'; END IF;
        IF EXISTS (
          SELECT 1 FROM catalog_nodes n JOIN catalog_texts t ON n.payload_type='CatalogText' AND t.id=n.payload_id
          WHERE n.project_id=NEW.project_id AND NOT n.deleted
          GROUP BY n.parent_id,t.locale HAVING count(*)>1
        ) THEN RAISE EXCEPTION 'Duplicate active translation'; END IF;
        RETURN NULL;
      END $$;
      CREATE CONSTRAINT TRIGGER catalog_shape AFTER INSERT OR UPDATE ON catalog_nodes
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION guard_catalog_shape();
    SQL
  end
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
