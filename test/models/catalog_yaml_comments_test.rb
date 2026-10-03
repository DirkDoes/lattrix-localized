require "test_helper"

class CatalogYamlCommentsTest < ActiveSupport::TestCase
  test "preserves header nested inline footer and removed-key comments without changing values" do
    original = <<~YAML
      # File documentation
      en:
        # Greeting documentation
        greeting: Hello # Inline greeting
        # Removed documentation
        removed: Old
        nested:
          name: Name # Nested comment
      # File footer
    YAML
    data = {"en" => {"nested" => {"name" => "Updated"}, "greeting" => "Welcome"}}
    result = CatalogYamlComments.preserve(original, YAML.dump(data))
    assert_equal data, YAML.safe_load(result)
    ['File documentation', 'Greeting documentation', 'Inline greeting', 'Removed documentation', 'Nested comment', 'File footer'].each do |comment|
      assert_equal 1, result.scan("# #{comment}").size
    end
    assert_match(/# Greeting documentation\n  # Inline greeting\n  greeting: Welcome/, result)
    assert_match(/# Nested comment\n    name: Updated/, result)
    assert_equal result, CatalogYamlComments.preserve(result, YAML.dump(data))
  end

  test "hashes inside scalars stay values and block headers retain real comments" do
    original = <<~'YAML'
      en:
        quoted: "A # literal" # Real quoted comment
        single: 'Another # literal'
        plain: abc#def
        block: | # Block instructions
          # This is translation text
          More text
        folded: >-
          # Also translation text
        multiline: "first
          # inside quotes"
        list: ["# item", 2] # List documentation
    YAML
    data = YAML.safe_load(original)
    result = CatalogYamlComments.preserve(original, YAML.dump(data))
    assert_equal data, YAML.safe_load(result)
    assert_equal 3, CatalogYamlComments.new(result).comments.size
    assert_includes result, '# Real quoted comment'
    assert_includes result, '# Block instructions'
    assert_includes result, '# List documentation'
  end
end
