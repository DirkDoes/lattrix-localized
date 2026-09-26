require "csv"
require "json"
require "yaml"
require "zip"
require "rexml/document"

class SheetImport
  class Error < StandardError
    attr_reader :files

    def initialize(message, files: nil)
      super(message)
      @files = files
    end
  end
  MAX_FILES = 20
  MAX_BYTES = 5.megabytes
  PLURAL_CATEGORIES = TranslationKey::PLURAL_CATEGORIES.to_set

  attr_reader :file_results, :settings, :language_ids

  def initialize(project:, uploads:, default_language_id:, delimiter: nil)
    @project = project
    @uploads = Array(uploads).reject { |upload| !upload.respond_to?(:read) || upload.original_filename.blank? }
    @default_language_id = default_language_id.to_i
    @requested_delimiter = delimiter.presence
    @translations = Hash.new { |hash, path| hash[path] = {} }
    @file_results = []
    parse!
  end

  def apply!(sheet:, actor:)
    raise Error, "Imported translations require the detected parent-translation setting" if !sheet.allow_parent_translations? && parent_translation_paths.any?
    change_id = RecordingEvent.connection.select_value("SELECT nextval('recording_event_change_ids')")
    created_at = Time.current
    records = {}
    events = []
    paths = (@translations.keys + @translations.keys.flat_map { |path| (1...path.length).map { |length| path.first(length) } }).uniq.sort_by { |path| [path.length, path] }
    plural_paths = sheet.pluralization_enabled? ? plural_parent_paths : Set.new

    paths.each do |path|
      payload = TranslationKey.create!(name: path.last, pluralized: plural_paths.include?(path))
      recording = Recording.create!(translation_tree: sheet.translation_tree, parent: records[path[0...-1]], recordable: payload)
      records[path] = recording
      events << event_attributes(recording, payload, actor, change_id, created_at)
    end
    @translations.each do |path, values|
      values.each do |language_id, text|
        next if text.blank?
        payload = TextTranslation.create!(language_id: language_id, text: text)
        recording = Recording.create!(translation_tree: sheet.translation_tree, parent: records.fetch(path), recordable: payload)
        events << event_attributes(recording, payload, actor, change_id, created_at)
      end
    end
    RecordingEvent.insert_all!(events)
  end

  def preview
    { files: file_results, settings: settings, language_ids: language_ids, translations: @translations.sum { |_path, values| values.count { |_language, text| text.present? } } }
  end

  private

  def parse!
    raise Error, "Choose at least one file" if @uploads.empty?
    raise Error, "Import at most #{MAX_FILES} files at once" if @uploads.length > MAX_FILES
    parsed = @uploads.map { |upload| parse_file(upload) }
    failures = parsed.select { |item| item[:error] }
    @file_results = parsed.map { |item| item.slice(:filename, :tone, :subtext, :error) }
    raise Error.new(failures.first[:error], files: @file_results) if failures.any?
    families = parsed.map { |item| item[:family] }.uniq
    raise Error, "Upload either language files or one CSV/Excel file, not both" if families.length > 1
    raise Error, "Upload only one CSV or Excel file" if families == [:table] && parsed.length > 1
    families.first == :table ? merge_table(parsed.first) : merge_language_files(parsed)
    detect_settings(families.first)
  end

  def parse_file(upload)
    filename = upload.original_filename.to_s.first(200)
    raise Error, "#{filename} is larger than 5 MB" if upload.size > MAX_BYTES
    extension = File.extname(filename).downcase
    data = case extension
    when ".json" then JSON.parse(read(upload))
    when ".yaml", ".yml" then YAML.safe_load(read(upload), permitted_classes: [], permitted_symbols: [], aliases: false)
    when ".csv" then CSV.parse(read(upload), headers: false)
    when ".xlsx" then xlsx_rows(upload)
    else raise Error, "#{filename} is not a JSON, YAML, CSV, or Excel file"
    end
    if %w[.json .yaml .yml].include?(extension)
      raise Error, "#{filename} must contain an object at its root" unless data.is_a?(Hash)
      language = language_for_filename(filename) || raise(Error, "No project language matches #{filename}")
      values = {}; flatten(data, [], values)
      { filename: filename, family: :language, language: language, values: values, tone: "success", subtext: "#{language.name} detected · #{values.length} keys" }
    else
      raise Error, "#{filename} needs a key column and at least one language column" if data.length < 2 || Array(data.first).length < 2
      { filename: filename, family: :table, rows: data, tone: "success", subtext: "#{extension == '.csv' ? 'CSV' : 'Excel'} detected · #{data.length - 1} rows" }
    end
  rescue JSON::ParserError, Psych::Exception, CSV::MalformedCSVError, Zip::Error, REXML::ParseException, Error => error
    { filename: filename, error: error.message, tone: "error", subtext: error.message }
  ensure
    upload.rewind if upload.respond_to?(:rewind)
  end

  def read(upload)
    upload.rewind
    upload.read(MAX_BYTES + 1).force_encoding(Encoding::UTF_8)
  end

  def identifier_languages
    @identifier_languages ||= @project.identifier_sets.order(:created_at, :id).flat_map(&:language_identifiers).each_with_object({}) do |identifier, map|
      key = identifier.identifier.downcase
      map[key] = map.key?(key) && map[key] != identifier.language ? nil : identifier.language
    end
  end

  def language_for_filename(filename)
    stem = File.basename(filename, ".*").downcase
    matches = identifier_languages.filter_map do |identifier, language|
      language if language && (stem == identifier || stem.match?(/(?:^|[._-])#{Regexp.escape(identifier)}(?:$|[._-])/))
    end.uniq
    matches.one? ? matches.first : nil
  end

  def language_for_header(header)
    identifier_languages[header.to_s.strip.downcase]
  end

  def flatten(node, path, values)
    if node.is_a?(Hash)
      node.each do |name, child|
        name = name.to_s
        if name == "0"
          raise Error, "A 0 parent value cannot be stored at the document root" if path.empty?
          raise Error, "A 0 parent value must be text" if child.is_a?(Hash) || child.is_a?(Array)
          values[path] = scalar(child)
        else
          flatten(child, path + [name], values)
        end
      end
    elsif node.is_a?(Array)
      raise Error, "Arrays are not supported in translation files"
    else
      raise Error, "A translation cannot be stored at the document root" if path.empty?
      values[path] = scalar(node)
    end
  end

  def scalar(value)
    value.nil? ? "" : value.to_s
  end

  def merge_language_files(parsed)
    duplicates = parsed.group_by { |item| item[:language].id }.select { |_id, items| items.many? }
    raise Error, "Each language can only be imported once" if duplicates.any?
    parsed.each { |item| item[:values].each { |path, text| @translations[path][item[:language].id] = text } }
    @language_ids = parsed.map { |item| item[:language].id }
    validate_default_language!
  end

  def merge_table(item)
    headers = item[:rows].first.map { |value| value.to_s.strip }
    languages = headers.drop(1).map { |header| language_for_header(header) }
    missing = headers.drop(1).zip(languages).filter_map { |header, language| header unless language }
    raise Error, "Unknown language #{missing.first.inspect}; use a project language identifier" if missing.any?
    raise Error, "Language columns must be unique" if languages.map(&:id).uniq.length != languages.length
    keys = item[:rows].drop(1).map { |row| Array(row).first.to_s }.reject(&:blank?)
    delimiter = @requested_delimiter || detect_delimiter(keys)
    item[:rows].drop(1).each do |row|
      row = Array(row)
      next if row.first.to_s.blank?
      path = split_key(row.first.to_s, delimiter)
      languages.each_with_index do |language, index|
        value = row[index + 1]
        @translations[path][language.id] = scalar(value) unless value.nil?
      end
    end
    @language_ids = languages.map(&:id)
    @detected_delimiter = delimiter
    validate_default_language!
  end

  def validate_default_language!
    raise Error, "Choose a default language included in the import" unless @language_ids.include?(@default_language_id)
  end

  def detect_delimiter(keys)
    %w[:: . / _ -].max_by { |candidate| [ keys.count { |key| key.include?(candidate) }, keys.sum { |key| key.count(candidate) } ] }.then do |candidate|
      keys.any? { |key| key.include?(candidate) } ? candidate : "."
    end
  end

  def split_key(key, delimiter)
    parts = key.split(delimiter)
    raise Error, "Key #{key.inspect} contains an empty level" if parts.any?(&:blank?)
    parts
  end

  def detect_settings(family)
    parents = parent_translation_paths
    plurals = plural_parent_paths
    pluralization = plurals.none? { |path| @translations[path].values.any?(&:present?) }
    @settings = {
      delimiter: family == :table ? @detected_delimiter : ".",
      wildcard_format: detect_wildcard,
      case_sensitive_keys: case_conflicts?,
      allow_parent_translations: parents.any?,
      pluralization_enabled: pluralization,
      missing_value_behavior: detect_missing_behavior(family)
    }
  end

  def parent_translation_paths
    @translations.keys.select { |path| @translations[path].values.any?(&:present?) && @translations.keys.any? { |other| other.length > path.length && other.first(path.length) == path } }.to_set
  end

  def plural_parent_paths
    children = @translations.keys.group_by { |path| path[0...-1] }.transform_values { |paths| paths.map(&:last).to_set }
    children.filter_map { |path, names| path if names.include?("one") && names.include?("other") }.to_set
  end

  def detect_wildcard
    @translations.each_value do |values|
      values.each_value do |text|
        match = text.match(/([$%#@]?\{|[$%#@]?\[)(?:[^}\]\r\n]+)(\}|\])/)
        return "#{match[1]}...#{match[2]}" if match
      end
    end
    ""
  end

  def detect_missing_behavior(family)
    return "omit" if @language_ids.one?
    default_values = @translations.transform_values { |values| values[@default_language_id] if values.key?(@default_language_id) }
    others = @language_ids - [@default_language_id]
    if family == :table
      return "omit" if @translations.any? { |path, values| default_values[path].present? && others.any? { |id| !values.key?(id) || values[id] == "" } }
      return "fallback"
    end
    return "empty" if @translations.any? { |path, values| default_values[path].present? && others.any? { |id| values.key?(id) && values[id] == "" } }
    return "omit" if @translations.any? { |path, values| default_values[path].present? && others.any? { |id| !values.key?(id) } }
    "fallback"
  end

  def case_conflicts?
    @translations.keys.group_by { |path| path.map(&:downcase) }.any? { |_path, variants| variants.uniq.many? }
  end

  def event_attributes(recording, payload, actor, change_id, created_at)
    { recording_id: recording.id, actor_id: actor&.id, action: "created", recordable_type: payload.class.name, recordable_id: payload.id, deleted_at: nil, change_type: "import", change_id: change_id, created_at: created_at }
  end

  def xlsx_rows(upload)
    Zip::File.open(upload.tempfile.path) do |zip|
      shared = if (entry = zip.find_entry("xl/sharedStrings.xml"))
        document = REXML::Document.new(entry.get_input_stream.read)
        REXML::XPath.match(document, "//*[local-name()='si']").map { |node| REXML::XPath.match(node, ".//*[local-name()='t']").map(&:text).join }
      else
        []
      end
      sheet = zip.find_entry("xl/worksheets/sheet1.xml") || raise(Error, "The workbook has no readable first worksheet")
      document = REXML::Document.new(sheet.get_input_stream.read)
      REXML::XPath.match(document, "//*[local-name()='row']").map do |row|
        values = []
        REXML::XPath.match(row, "./*[local-name()='c']").each do |cell|
          column = cell.attributes["r"].to_s[/[A-Z]+/].to_s.chars.reduce(0) { |sum, char| sum * 26 + char.ord - 64 } - 1
          raw = REXML::XPath.first(cell, ".//*[local-name()='v']")&.text || REXML::XPath.match(cell, ".//*[local-name()='t']").map(&:text).join
          values[column] = cell.attributes["t"] == "s" ? shared[raw.to_i] : raw
        end
        values
      end
    end
  end
end
