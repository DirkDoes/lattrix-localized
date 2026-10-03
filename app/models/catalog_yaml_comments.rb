# Comments belong to repository files, not catalog records. Psych supplies
# scalar ranges so hashes inside quoted/plain/block text are never comments.
class CatalogYamlComments
  def self.preserve(original, generated)
    return generated if original.blank? || !original.include?('#')
    source = new(original)
    target = new(generated)
    targets = target.anchors.index_by { |entry| entry[:path] }
    before = Hash.new { |hash, key| hash[key] = [] }
    source.comments.each do |path, comment|
      anchor = targets[path]
      line = anchor ? anchor[:line] : generated.lines.length
      indent = anchor ? anchor[:column] : 0
      before[line] << "#{' ' * indent}#{comment}\n"
    end
    result = generated.lines.each_with_index.map { |line, index| before[index].join + line }.join
    result + before[generated.lines.length].join
  end

  attr_reader :anchors

  def initialize(text)
    @lines = text.lines
    @anchors, @scalar_ranges = [], Hash.new { |hash, key| hash[key] = [] }
    walk(Psych.parse_stream(text), [])
    @anchors.sort_by! { |entry| [entry[:line], entry[:column]] }
  end

  def comments
    @lines.each_with_index.filter_map do |line, index|
      column = line.each_char.with_index.find do |character, offset|
        character == '#' && (offset.zero? || line[offset - 1].match?(/\s/)) &&
          @scalar_ranges[index].none? { |range| range.cover?(offset) }
      end&.last
      next unless column
      inline = line[0...column].strip.present?
      following = anchors.bsearch_index { |entry| entry[:line] > index } || anchors.length
      anchor = inline ? (anchors[following - 1] if following.positive?) : anchors[following]
      [anchor&.fetch(:path), line[column..].delete_suffix("\n").delete_suffix("\r")]
    end
  end

  private

  def walk(node, path)
    if node.is_a?(Psych::Nodes::Scalar)
      (node.start_line..node.end_line).each do |line|
        # A block scalar's header may have a real comment; its body cannot.
        next if line == node.start_line && [Psych::Nodes::Scalar::LITERAL, Psych::Nodes::Scalar::FOLDED].include?(node.style)
        start = line == node.start_line ? node.start_column : 0
        finish = line == node.end_line ? node.end_column : @lines.fetch(line, '').length
        @scalar_ranges[line] << (start...finish)
      end
    elsif node.is_a?(Psych::Nodes::Mapping)
      node.children.each_slice(2) do |key, value|
        child_path = path + [key.is_a?(Psych::Nodes::Scalar) ? key.value : key.start_column]
        @anchors << {path: child_path, line: key.start_line, column: key.start_column}
        walk(key, child_path)
        walk(value, child_path)
      end
    else
      Array(node.children).each_with_index { |child, index| walk(child, node.is_a?(Psych::Nodes::Sequence) ? path + [index] : path) }
    end
  end
end
