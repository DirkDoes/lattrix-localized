require "test_helper"
require "minitest/mock"

class CatalogGithubTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Git catalog")
    @writer = CatalogWriter.new(@project)
    @commit = {"sha"=>"abc", "commit"=>{"tree"=>{"sha"=>"tree"}, "author"=>{"name"=>"Developer"}}}
  end
  def edit(&block) = @writer.edit(expected: @project.reload.revision, &block)
  def state = CatalogState.new(@project, pending: true)
  def key(path) = state.keys.find { |item| state.path(item) == path }
  def sync(files, sha = "abc") = CatalogReconcile.new(@project, files.transform_values { |v| YAML.dump(v) }, sha: sha).apply!

  test "identical independently created keys resolve drafts without duplicates" do
    @project.update!(repository: "org/repo")
    edit { |w| w.add_key("name") }
    edit { |w| w.translate(key("name").id, "en", "Name") }
    sync("en"=>{"en"=>{"name"=>"Name"}})
    assert_empty @project.catalog_drafts
    assert_equal 1, CatalogState.new(@project).keys.size
    assert_equal "Name", CatalogExport.new(@project).values.dig("en", "name")
  end

  test "source deletion removes target values and leaves local edits conflicted" do
    sync({"en"=>{"en"=>{"name"=>"Name"}}, "nl"=>{"nl"=>{"name"=>"Naam"}}})
    @project.update!(repository: "org/repo")
    edit { |w| w.translate(key("name").id, "nl", "Nieuwe naam") }
    sync({"en"=>{"en"=>{}}, "nl"=>{"nl"=>{}}}, "deleted")
    assert_empty CatalogExport.new(@project).values
    assert @project.catalog_drafts.sole.conflict?
  end

  test "removing locale files archives without deleting retained values" do
    sync({"en"=>{"en"=>{"name"=>"Name"}}, "nl"=>{"nl"=>{"name"=>"Naam"}}})
    sync({"en"=>{"en"=>{"name"=>"Name"}}}, "archived")
    assert @project.languages.find_by!(identifier: "nl").archived?
    assert_equal "Naam", CatalogState.new(@project).translation(key("name").id, "nl").payload.value
    assert_nil CatalogExport.new(@project).values["nl"]
  end

  test "initial connection proposes local only keys and conflicts for differing strings" do
    edit { |w| w.add_key("name"); w.add_key("local") }
    edit { |w| w.translate(key("name").id, "en", "Local name"); w.translate(key("local").id, "en", "Local only") }
    @project.update!(repository: "org/repo", installation_id: 1, git_branch: "trunk")
    api = Minitest::Mock.new
    api.expect(:snapshot, [@commit, {"en"=>YAML.dump({"en"=>{"name"=>"Remote name", "remote"=>"Remote only"}})}])
    CatalogGithub.stub(:new, api) { CatalogSyncJob.perform_now(@project.id, initial: true) }
    api.verify
    assert_nil @project.reload.sync_error
    assert @project.catalog_drafts.where(conflict: true).exists?
    assert_equal "Local only", state.translation(key("local").id, "en").payload.value
    assert_equal "Remote only", CatalogExport.new(@project).values.dig("en", "remote")
  end

  test "closing a PR preserves drafts and creates a fresh PR on publication" do
    @project.update!(repository: "org/repo", installation_id: 1, git_branch: "trunk", pull_request_number: 8)
    edit { |w| w.add_key("name") }
    calls = []
    responder = lambda do |method, path, data = nil|
      calls << [method, path, data]
      case path
      when /git\/trees$/ then {"sha"=>"new-tree"}
      when /git\/commits$/ then {"sha"=>"new-commit"}
      when /pulls\/8$/ then {"state"=>"closed", "number"=>8}
      when /git\/refs$/ then {}
      when /pulls$/ then {"number"=>9}
      else raise "Unexpected API request #{path}"
      end
    end
    CatalogGithub.new(@project).stub(:request, responder) do |api|
      api.publish!(@commit, {"en"=>"en: {}\n"}, {})
    end
    assert_equal 9, @project.reload.pull_request_number
    assert @project.catalog_drafts.exists?
    assert calls.any? { |method, path, _| method == :post && path.end_with?("/pulls") }
    assert_not calls.any? { |method, _, _| method == :patch }
  end

  test "unsupported yaml values are retained unless a managed path overwrites them" do
    edit { |w| w.add_key("name") }
    edit { |w| w.translate(key("name").id, "en", "Name") }
    files = CatalogExport.new(@project).files(existing: {"en"=>{"name"=>[1,2], "enabled"=>true, "amount"=>7}})
    assert_equal({"en"=>{"name"=>"Name", "enabled"=>true, "amount"=>7}}, YAML.safe_load(files["en"]))
  end

  test "other only source languages infer plural nodes" do
    @project.update!(source_locale: "ja")
    sync("ja"=>{"ja"=>{"items"=>{"other"=>"%{count} items"}}})
    assert_equal "plural", key("items").payload.kind
    assert_empty state.invalid_groups
  end

  test "historical Git export uses the same validation without changing current state" do
    sync("en"=>{"en"=>{"name"=>"Current"}})
    revision = @project.reload.revision
    counts = [CatalogNode.count, CatalogText.count, CatalogEvent.count]
    files = {"en"=>YAML.dump({"en"=>{"old"=>"Old value"}})}
    data = CatalogReconcile.preview(@project, files, sha: "old") { |snapshot| CatalogExport.new(@project, state: snapshot).values }
    assert_equal({"en"=>{"old"=>"Old value"}}, data)
    assert_equal revision, @project.reload.revision
    assert_equal counts, [CatalogNode.count, CatalogText.count, CatalogEvent.count]
    assert_equal "Current", CatalogExport.new(@project).values.dig("en", "name")
  end

  test "malformed YAML and duplicate keys are rejected" do
    assert_raises(ArgumentError) { CatalogYaml.new("en"=>"en:\n  name: first\n  name: second\n") }
    assert_raises(ArgumentError) { CatalogYaml.new("en"=>"en: [broken") }
  end

  test "invalid version previews do not block the live catalog" do
    sync("en"=>{"en"=>{"name"=>"Current"}})
    assert_raises(ArgumentError) do
      CatalogReconcile.preview(@project, {"en"=>"en:\n  invalid: '%{count}'\n"}, sha: "invalid") { |snapshot| CatalogExport.new(@project, state: snapshot).values }
    end
    assert_nil @project.reload.sync_error
    assert_equal "Current", CatalogExport.new(@project).values.dig("en", "name")
  end
end
