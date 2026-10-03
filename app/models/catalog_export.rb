require "csv"
require "yaml"
require "zip"
require "caxlsx"
class CatalogExport
  def initialize(project, state: CatalogState.new(project))
    @project, @state = project, state
  end
  def values
    invalid = @state.invalid_groups
    @state.texts.each_with_object({}) do |text, out|
      next unless @state.locales.include?(text.payload.locale)
      next if invalid.key?(@state.group_for(text))
      (out[text.payload.locale] ||= {})[@state.path(@state.items.fetch(text.parent_id))] = text.payload.value
    end
  end
  def files(existing: {}, originals: {})
    content = values
    roots = @state.keys.select { |key| key.parent_id.nil? }.to_h { |key| [key.payload.name, key.payload.file_group] }
    trees = existing.transform_values { |tree| CatalogYaml.without_strings(tree) }
    filenames = existing.keys.to_h { |file| [CatalogYaml.identity(file), file] }
    # Keep old files (including unsupported YAML values), removing managed strings
    # from their previous location when a root is reassigned.
    @state.locales.each do |locale|
      groups = roots.values.uniq.presence || [""]
      groups.each do |group|
        file = filenames[[group, locale]] || [group.presence, locale].compact.join('.')
        trees[file] ||= {}
      end
      content.fetch(locale, {}).sort.each do |path, value|
        group = roots.fetch(path.split('.').first)
        file = filenames[[group, locale]] || [group.presence, locale].compact.join('.')
        CatalogYaml.assign(trees.fetch(file), path, value)
      end
    end
    trees.to_h do |file, tree|
      generated = YAML.dump({CatalogYaml.identity(file).last => tree})
      [file, CatalogYamlComments.preserve(originals[file], generated)]
    end
  end
  def download(format)
    case format
    when "yaml"
      data = Zip::OutputStream.write_buffer { |zip| files.each { |file, text| zip.put_next_entry(CatalogYaml.filename(file)); zip.write(text) } }.string
      [data, "#{@project.slug}.zip", "application/zip"]
    when "csv", "xlsx"
      content = values
      locales = @state.locales.sort
      paths = content.values.flat_map(&:keys).uniq.sort
      rows = [["key", *locales]] + paths.map { |path| [path, *locales.map { |locale| content.dig(locale, path) }] }
      if format == "csv"
        [CSV.generate { |csv| rows.each { |row| csv << row } }, "#{@project.slug}.csv", "text/csv"]
      else
        package = Axlsx::Package.new
        package.workbook.add_worksheet(name: "Translations") { |sheet| rows.each { |row| sheet.add_row(row, types: Array.new(row.size, :string), escape_formulas: true) } }
        [package.to_stream.read, "#{@project.slug}.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"]
      end
    else raise ArgumentError, "Choose YAML, CSV or Excel"
    end
  end
end
