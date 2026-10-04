require "yaml"
class CatalogYaml
  attr_reader :documents, :values, :root_groups
  def self.identity(filename)
    stem = filename.sub(/\.ya?ml\z/, "")
    group, _, locale = stem.rpartition(".")
    raise ArgumentError, "Unknown locale #{locale}" unless CatalogLocale.valid?(locale)
    raise ArgumentError, "Invalid file group #{group.inspect}; use lowercase letters, digits, dots, underscores or hyphens" unless group.length <= 100 && group.match?(CatalogKey::FILE_GROUP_FORMAT)
    [group, locale]
  end

  def self.filename(file) = file.match?(/\.ya?ml\z/) ? file : "#{file}.yml"

  def initialize(files, project = nil)
    @documents, @values, @root_groups = {}, {}, {}
    identities = Set.new
    max_files, max_file, max_total = project ? [project.max_locale_files, project.max_locale_file_mb, project.max_locale_total_mb] : [100, 3, 15]
    raise ArgumentError, "Locale files exceed the project limit of #{max_files} files" if files.size > max_files
    raise ArgumentError, "Locale files exceed #{max_total} MB combined" if files.values.sum(&:bytesize) > max_total.megabytes
    files.each do |file, content|
      group, locale = self.class.identity(file)
      raise ArgumentError, "Duplicate locale file for #{file}" unless identities.add?([group, locale])
      raise ArgumentError, "#{file}: locale file exceeds #{max_file} MB" if content.bytesize > max_file.megabytes
      stack = [[Psych.parse_stream(content), 0]]
      until stack.empty?
        node, depth = stack.pop
        raise ArgumentError, "YAML nesting is too deep" if depth > 100
        if node.is_a?(Psych::Nodes::Mapping)
          names = node.children.each_slice(2).map(&:first).filter_map { |key| key.value if key.is_a?(Psych::Nodes::Scalar) }
          raise ArgumentError, "Duplicate YAML keys are not supported" unless names.uniq.size == names.size
        end
        Array(node.children).each { |child| stack << [child, depth + 1] }
      end
      data = YAML.safe_load(content, permitted_classes: [], permitted_symbols: [], aliases: false)
      raise ArgumentError, "#{locale}.yml must contain exactly one #{locale}: root" unless data.is_a?(Hash) && data.keys == [locale] && data[locale].is_a?(Hash)
      @documents[file] = data[locale]
      flat = {}
      flatten(data[locale], [], flat)
      flat.each do |path, value|
        root = path.split('.').first
        if @root_groups.key?(root) && @root_groups[root] != group
          raise ArgumentError, "Root #{root} occurs in different file groups; keep each root in one file group across languages"
        end
        @root_groups[root] = group
        (@values[locale] ||= {})[path] = value
      end
      @values[locale] ||= {}
    end
  rescue Psych::Exception => error
    raise ArgumentError, "Invalid YAML: #{error.message}"
  end

  def flatten(hash, prefix, result)
    hash.each do |segment, value|
      next unless segment.is_a?(String)
      if value.is_a?(Hash) || value.is_a?(String)
        raise ArgumentError, "Invalid key segment #{segment.inspect}" if segment.blank? || segment.match?(/[.\s]/)
      end
      path = prefix + [segment]
      if value.is_a?(Hash)
        flatten(value, path, result)
      elsif value.is_a?(String)
        result[path.join(".")] = value
      end
    end
  end

  def self.without_strings(hash)
    hash.each_with_object({}) do |(key, value), out|
      if value.is_a?(Hash)
        child = without_strings(value)
        out[key] = child if child.any?
      elsif !value.is_a?(String)
        out[key] = value
      end
    end
  end

  def self.assign(hash, path, value)
    parts = path.split("."); leaf = parts.pop
    parent = parts.reduce(hash) { |memo, name| memo[name] = {} unless memo[name].is_a?(Hash); memo[name] }
    parent[leaf] = value
  end
end
