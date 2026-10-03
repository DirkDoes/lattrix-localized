require "test_helper"

class ProjectCompletionTermsTest < ActiveSupport::TestCase
  test "normalizes terms, ignores blank rows and rejects oversized or nameless terms" do
    project = Project.new(name: "Terms", completion_terms: [{text: " Hello ", description: " Greeting "}, {text: "hello"}, {text: "", description: ""}])
    assert project.valid?
    assert_equal [{"text" => "Hello", "description" => "Greeting"}], project.completion_terms
    project.completion_terms = [{description: "Missing term"}]
    assert_not project.valid?
    assert project.errors[:completion_terms].present?
    project.completion_terms = [{text: "x" * 101}]
    assert_not project.valid?
  end
end
