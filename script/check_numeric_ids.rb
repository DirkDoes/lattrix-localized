# Run only on a restored, disposable copy: rails runner script/check_numeric_ids.rb
config = ActiveRecord::Base.connection_db_config.configuration_hash.merge(database: "lattrix_numeric_rehearsal", url: nil)
ActiveRecord::Base.establish_connection(config)
c = ActiveRecord::Base.connection
raise "Wrong database" unless c.current_database == "lattrix_numeric_rehearsal"
load Rails.root.join("db/migrate/20260921000000_use_numeric_application_ids.rb")
ActiveRecord::Migration.verbose = false
tables = UseNumericApplicationIds::TABLES + %w[users solid_queue_jobs]
snapshot = -> { tables.to_h { |table| [table, c.select_value("SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb)::text FROM #{table} t")] } }
before = snapshot.call
ActiveRecord::Base.transaction { UseNumericApplicationIds.new.migrate(:up) }
UseNumericApplicationIds::TABLES.each do |table|
  raise "Not numeric: #{table}" unless c.columns(table).find { |column| column.name == "id" }.sql_type == "bigint"
end
raise "User UUID changed" unless c.columns("users").find { |column| column.name == "id" }.sql_type == "uuid"
raise "Broken payload references" unless c.select_value("SELECT count(*) FROM recordings r WHERE (recordable_type='TranslationKey' AND NOT EXISTS(SELECT 1 FROM translation_keys k WHERE k.id=r.recordable_id)) OR (recordable_type='TextTranslation' AND NOT EXISTS(SELECT 1 FROM text_translations t WHERE t.id=r.recordable_id))").zero?
raise "Disabled triggers" unless c.select_value("SELECT count(*) FROM pg_trigger WHERE tgrelid IN (SELECT oid FROM pg_class WHERE relnamespace='public'::regnamespace) AND tgenabled='D'").zero?
ActiveRecord::Base.transaction { UseNumericApplicationIds.new.migrate(:down) }
raise "Rollback changed data" unless snapshot.call == before
ActiveRecord::Base.transaction { UseNumericApplicationIds.new.migrate(:up) }
puts "PASS: all 17 tables numeric; users unchanged; payload references and triggers valid; rollback restores every row; second migration succeeds."
