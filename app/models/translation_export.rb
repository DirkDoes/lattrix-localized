require "csv"
require "yaml"
require "zip"
class TranslationExport
  def initialize(sheet, languages: nil, identifiers: {}, descriptions: false, checkpoint: nil)
    @sheet = sheet
    @languages, @identifiers, @descriptions, @checkpoint = languages, identifiers, descriptions, checkpoint
  end

  def generate(format)
    # Repeatable-read keeps the export internally consistent without locking out editors.
    options = ApplicationRecord.connection.transaction_open? ? {} : {isolation: :repeatable_read}
    ApplicationRecord.transaction(**options) do
      languages = @languages || @sheet.active_languages.order(:identifier).to_a
      records = @sheet.translation_tree.recordings.active.includes(:recordable).to_a
      keys = records.select(&:translation_key?).index_by(&:id)
      values = records.select(&:text_translation?).each_with_object({}) { |r, out| out[[r.parent_id, r.recordable.language_id]] = r.recordable.text }
      children = keys.values.group_by(&:parent_id)
      @plural_forms = keys.values.select { |key| @sheet.pluralization_enabled? && keys[key.parent_id]&.recordable&.pluralized && TranslationKey::PLURAL_CATEGORIES.include?(key.recordable.name) }.map(&:id).to_set
      @translated_keys = values.keys.map(&:first).to_set
      if %w[csv rows].include?(format)
        rows = [["key", *(@descriptions ? ["description"] : []), *languages.map { |language| @identifiers.fetch(language.id, language.identifier) }]]
        walk(children, nil, []) do |key, path|
          row = languages.map { |lang| value(values, key.id, lang.id) }
          next if children[key.id].present? && !@translated_keys.include?(key.id)
          rows << [path.map { |part| escape_segment(part) }.join(@sheet.delimiter), *(@descriptions ? [key.recordable.description] : []), *row] if row.any? { |v| !v.nil? }
        end
        format == "rows" ? rows : CSV.generate { |csv| rows.each { |row| csv << row } }

      else
        result = languages.to_h { |lang| [@identifiers.fetch(lang.id, lang.identifier), nested(children, nil, values, lang.id)] }
        Zip::OutputStream.write_buffer do |zip|
          result.each do |identifier, tree|
            zip.put_next_entry("#{identifier}.#{format}")
            zip.write(format == "json" ? JSON.pretty_generate(tree) : YAML.dump(tree))
          end
        end.string
      end
    end
  end

  private
  def escape_segment(part)
    part.gsub(Regexp.union("\\", @sheet.delimiter)) { |character| "\\#{character}" }
  end
  def value(values, key, language)
    return values[[key, language]] if values.key?([key, language])
    return nil if @plural_forms.include?(key)
    case @sheet.missing_value_behavior
    when "empty" then ""
    when "fallback" then values[[key, @sheet.default_language_id]]
    end
  end
  def walk(children, parent, prefix, &block)
    Array(children[parent]).sort_by { |r| r.recordable.name }.each do |key|
      @checkpoint&.call
      path = prefix + [key.recordable.name]
      yield key, path
      walk(children, key.id, path, &block)
    end
  end
  def nested(children, parent, values, language)
    Array(children[parent]).sort_by { |r| r.recordable.name }.each_with_object({}) do |key, out|
      @checkpoint&.call
      name = key.recordable.name.gsub("\\") { "\\\\" }
      name = "\\0" if name == "0"
      own = value(values, key.id, language)
      own = nil if children[key.id].present? && !@translated_keys.include?(key.id)
      descendants = nested(children, key.id, values, language)
      if descendants.any?
        if !own.nil?
          descendants = {"0" => own}.merge(descendants)
        end
        out[name] = descendants
      elsif !own.nil?
        out[name] = own
      end
    end
  end
end
