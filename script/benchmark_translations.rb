# Run with: bin/rails runner -e test script/benchmark_translations.rb
# All generated data is rolled back. Never run against the development/user database.
require "benchmark"
abort "Use the isolated test database" unless Rails.env.test? && ApplicationRecord.connection_db_config.database.end_with?("_test")
ActiveRecord::Base.logger = nil
$stdout.sync = true
ApplicationRecord.transaction do
  project = Project.create!(name: "Translation benchmark #{SecureRandom.hex(4)}")
  sheet = project.sheets.create!(name: "Large sheet")
  14.times { |n| project.languages.create!(name: "Language #{n}",identifier: "lang-#{n}",enabled: true) }
  tree = sheet.translation_tree
  connection = ApplicationRecord.connection
  count = Integer(ENV.fetch("BENCHMARK_KEYS", "10000")).clamp(100,10000)
  quote = ->(value) { connection.quote(value) }
  puts "Seeding #{count} keys × 15 languages for read benchmarks…"
  # Fixture-only bulk load; integrity guards are exercised separately by translation_structure_test.
  elapsed = Benchmark.realtime do
    connection.execute(<<~SQL)
      ALTER TABLE recordings DISABLE TRIGGER USER;
      CREATE TEMP TABLE benchmark_keys ON COMMIT DROP AS SELECT n, gen_random_uuid() AS id, gen_random_uuid() AS payload_id FROM generate_series(0,#{count-1}) n;
      CREATE UNIQUE INDEX ON benchmark_keys(n);
      INSERT INTO translation_keys(id,name,created_at,updated_at) SELECT payload_id, CASE WHEN n%100=0 THEN 'group_' ELSE 'key_' END || lpad(n::text,5,'0'), NOW(),NOW() FROM benchmark_keys;
      INSERT INTO recordings(id,translation_tree_id,parent_id,recordable_type,recordable_id,created_at,updated_at)
      SELECT k.id,#{quote.call(tree.id)},CASE WHEN k.n%100=0 THEN NULL ELSE p.id END,'TranslationKey',k.payload_id,NOW(),NOW()
      FROM benchmark_keys k JOIN benchmark_keys p ON p.n=k.n-k.n%100 ORDER BY k.n;
      CREATE TEMP TABLE benchmark_values ON COMMIT DROP AS SELECT k.id AS parent_id,l.id AS language_id,gen_random_uuid() AS payload_id FROM benchmark_keys k CROSS JOIN languages l WHERE l.project_id=#{quote.call(project.id)};
      INSERT INTO text_translations(id,language_id,text,created_at,updated_at) SELECT payload_id,language_id,'Representative translation content for ' || parent_id::text,NOW(),NOW() FROM benchmark_values;
      INSERT INTO recordings(translation_tree_id,parent_id,recordable_type,recordable_id,created_at,updated_at)
      SELECT #{quote.call(tree.id)},parent_id,'TextTranslation',payload_id,NOW(),NOW() FROM benchmark_values;
      ALTER TABLE recordings ENABLE TRIGGER USER;
      ANALYZE recordings;
      ANALYZE translation_keys;
      ANALYZE text_translations;
    SQL
  end
  puts "Seed: #{elapsed.round(2)} seconds"
  languages = sheet.active_languages.limit(2).pluck(:id)
  %w[alphabetical recent relevance].each do |sort|
    timings=3.times.map { connection.clear_query_cache; Benchmark.realtime { rows=tree.key_rows(sort:sort,languages:languages,limit:51); raise "Unbounded response" unless rows.size==51 } }
    puts "Flat #{sort}: #{(timings.sort[1]*1000).round} ms median, 51 rows"
  end
  puts "Tree: #{(Benchmark.realtime { tree.key_rows(view:'tree',languages:languages,limit:51) }*1000).round} ms, 51 rows"
  key=tree.recordings.active.keys.first
  puts "Edit: #{(Benchmark.realtime { key.save_translation!(sheet.default_language, 'Updated benchmark value') }*1000).round} ms"
  bytes=0
  elapsed=Benchmark.realtime { bytes=TranslationExport.new(sheet).generate('csv').bytesize }
  puts "CSV: #{elapsed.round(2)} seconds, #{bytes} bytes"
  raise ActiveRecord::Rollback
end
