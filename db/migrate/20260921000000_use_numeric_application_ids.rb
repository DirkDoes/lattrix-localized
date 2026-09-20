# Keep the mapping solely for immediate rollback of this pre-release conversion.
class UseNumericApplicationIds < ActiveRecord::Migration[8.1]
  TABLES = %w[auth_identities email_challenges export_requests identifier_sets invitations language_identifiers languages membership_languages project_invites project_memberships projects recordings sheet_languages sheets text_translations translation_keys translation_trees].freeze

  def up
    create_table :numeric_id_mappings, id: false do |t|
      t.string :table_name, null: false
      t.uuid :old_id, null: false
      t.bigint :new_id, null: false
    end
    add_index :numeric_id_mappings, [:table_name, :old_id], unique: true
    add_index :numeric_id_mappings, [:table_name, :new_id], unique: true
    add_column :email_challenges, :digest_token, :string
    add_column :export_requests, :storage_key, :string
    execute "UPDATE email_challenges SET digest_token=id::text"
    execute "UPDATE export_requests SET storage_key=id::text"
    TABLES.each do |table|
      execute "INSERT INTO numeric_id_mappings SELECT '#{table}', id, row_number() OVER (ORDER BY id) FROM #{table}"
    end
    convert(:up)
  end

  def down
    # Roll back before reopening writes; a backup is also taken before deployment.
    TABLES.each do |table|
      raise ActiveRecord::IrreversibleMigration, "New records exist; restore the pre-migration backup" if select_value("SELECT EXISTS(SELECT 1 FROM #{table} t WHERE NOT EXISTS(SELECT 1 FROM numeric_id_mappings m WHERE m.table_name='#{table}' AND m.new_id=t.id))")
    end
    convert(:down)
    remove_column :email_challenges, :digest_token
    remove_column :export_requests, :storage_key
    drop_table :numeric_id_mappings
  end

  private

  def convert(direction)
    forward = direction == :up
    source, target = forward ? %w[old_id new_id] : %w[new_id old_id]
    type = forward ? "bigint" : "uuid"
    foreign_keys = select_all(<<~SQL).to_a
      SELECT conrelid::regclass::text AS source_table, conname AS name,
             confrelid::regclass::text AS target_table, pg_get_constraintdef(oid) AS definition,
             (SELECT attname FROM pg_attribute WHERE attrelid=conrelid AND attnum=conkey[1]) AS column_name
      FROM pg_constraint WHERE contype='f' AND connamespace='public'::regnamespace
    SQL
    columns = TABLES.to_h { |table| [table, {"id" => table}] }
    foreign_keys.each do |fk|
      next unless TABLES.include?(fk['target_table'])
      (columns[fk['source_table']] ||= {})[fk['column_name']] = fk['target_table']
    end
    columns['recordings']['recordable_id'] = :polymorphic
    execute "SET LOCAL lock_timeout='10s'"
    execute "LOCK TABLE #{columns.keys.join(', ')} IN ACCESS EXCLUSIVE MODE"
    columns.each_key { |table| execute "ALTER TABLE #{table} DISABLE TRIGGER USER" }
    foreign_keys.each { |fk| execute "ALTER TABLE #{fk['source_table']} DROP CONSTRAINT #{quote_column_name(fk['name'])}" }
    execute <<~SQL
      CREATE OR REPLACE FUNCTION pg_temp.convert_id(table_key text, original #{forward ? 'uuid' : 'bigint'}) RETURNS #{type}
      LANGUAGE plpgsql STRICT AS $$
      DECLARE result #{type};
      BEGIN
        SELECT #{target} INTO STRICT result FROM numeric_id_mappings WHERE table_name=table_key AND #{source}=original;
        RETURN result;
      END $$;
    SQL
    columns.each do |table, fields|
      execute "ALTER TABLE #{table} ALTER COLUMN id DROP DEFAULT" if TABLES.include?(table)
      changes = fields.map do |field, referenced|
        reference = referenced == :polymorphic ? "CASE recordable_type WHEN 'TranslationKey' THEN 'translation_keys' WHEN 'TextTranslation' THEN 'text_translations' END" : quote(referenced)
        "ALTER COLUMN #{quote_column_name(field)} TYPE #{type} USING pg_temp.convert_id(#{reference}, #{quote_column_name(field)})"
      end
      execute "ALTER TABLE #{table} #{changes.join(', ')}"
      next unless TABLES.include?(table)
      if forward
        execute "CREATE SEQUENCE #{table}_id_seq OWNED BY #{table}.id"
        execute "SELECT setval('#{table}_id_seq', COALESCE((SELECT max(id)+1 FROM #{table}),1), false)"
        execute "ALTER TABLE #{table} ALTER COLUMN id SET DEFAULT nextval('#{table}_id_seq')"
      else
        execute "DROP SEQUENCE #{table}_id_seq"
        execute "ALTER TABLE #{table} ALTER COLUMN id SET DEFAULT gen_random_uuid()"
      end
    end
    %w[guard_recording guard_sheet_languages].each do |name|
      definition = select_value("SELECT pg_get_functiondef('#{name}()'::regprocedure)")
      execute definition.gsub(/(lang|project) #{forward ? 'uuid' : 'bigint'};/, "\\1 #{type};")
    end
    remap_embedded_ids(source, target)
    foreign_keys.each { |fk| execute "ALTER TABLE #{fk['source_table']} ADD CONSTRAINT #{quote_column_name(fk['name'])} #{fk['definition']}" }
    columns.each_key { |table| execute "ALTER TABLE #{table} ENABLE TRIGGER USER" }
  end

  def remap_embedded_ids(source, target)
    maps = select_all("SELECT table_name, #{source} AS source, #{target} AS target FROM numeric_id_mappings").group_by { |row| row['table_name'] }.transform_values { |rows| rows.to_h { |row| [row['source'].to_s, row['target']] } }
    map_id = ->(table, id) { maps.fetch(table, {}).fetch(id.to_s, id) }
    select_all("SELECT id, options FROM export_requests").each do |row|
      options = JSON.parse(row['options'])
      %w[sheet language].each { |kind| options["#{kind}_ids"] = Array(options["#{kind}_ids"]).map { |id| map_id.call("#{kind}s", id) } }
      options['identifier_set_id'] = map_id.call('identifier_sets', options['identifier_set_id'])
      execute "UPDATE export_requests SET options=#{quote(options.to_json)}::jsonb WHERE id=#{quote(row['id'])}"
    end
    select_all("SELECT id, arguments FROM solid_queue_jobs WHERE class_name IN ('ExportJob','ExportCleanupJob')").each do |row|
      arguments = JSON.parse(row['arguments'])
      arguments['arguments'][0] = map_id.call('export_requests', arguments['arguments'][0])
      execute "UPDATE solid_queue_jobs SET arguments=#{quote(arguments.to_json)} WHERE id=#{row['id']}"
    end
  end
end
