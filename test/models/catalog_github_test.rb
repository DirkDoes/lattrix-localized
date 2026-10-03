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

  test "file groups merge locales and split YAML without changing CSV paths" do
    sync({"en"=>{"en"=>{"hello"=>"Hello"}}, "devise.en"=>{"en"=>{"devise"=>{"login"=>"Sign in"}, "errors"=>{"missing"=>"Missing"}}}, "devise.nl.yaml"=>{"nl"=>{"devise"=>{"login"=>"Inloggen"}}}})
    assert_equal "devise", key("devise").payload.file_group
    assert_equal "devise", state.file_group(key("errors.missing"))
    assert_equal "", key("hello").payload.file_group
    files = CatalogExport.new(@project).files
    assert_equal({"en"=>{"hello"=>"Hello"}}, YAML.safe_load(files.fetch("en")))
    assert_equal "Sign in", YAML.safe_load(files.fetch("devise.en")).dig("en", "devise", "login")
    assert_equal "Inloggen", YAML.safe_load(files.fetch("devise.nl")).dig("nl", "devise", "login")
    csv = CatalogExport.new(@project).download("csv").first
    assert_includes csv, "devise.login"
    assert_not_includes csv, "devise.devise.login"
  end

  test "file group changes remove old managed strings preserve unsupported values and restore inclusively" do
    originals = {"en"=>{"en"=>{"hello"=>"Hello"}}, "devise.en.yaml"=>{"en"=>{"devise"=>{"login"=>"Sign in"}, "enabled"=>true}}}
    sync(originals)
    position = @project.catalog_events.maximum(:id)
    root = key("devise")
    edit { |w| w.change_key(root.id, name: "devise", kind: "branch", file_group: "  Accounts ") }
    assert_equal "accounts", key("devise").payload.file_group
    parsed = CatalogYaml.new(originals.transform_values { |v| YAML.dump(v) })
    files = CatalogExport.new(@project).files(existing: parsed.documents)
    assert_equal({"en"=>{"enabled"=>true}}, YAML.safe_load(files.fetch("devise.en.yaml")))
    assert_equal "Sign in", YAML.safe_load(files.fetch("accounts.en")).dig("en", "devise", "login")
    assert_equal "devise", CatalogState.new(@project, at: position).file_group(CatalogState.new(@project, at: position).items.fetch(root.id))
    @writer.restore(position, expected: @project.reload.revision)
    assert_equal "devise", key("devise").payload.file_group
    files = CatalogExport.new(@project).files(existing: parsed.documents)
    assert files.key?("devise.en.yaml")
    assert_not files.key?("devise.en")
  end

  test "file group parser rejects ambiguous roots and unsafe filenames without reserving default" do
    parsed = CatalogYaml.new("default.en"=>"en:\n  default: Fine\n")
    assert_equal "default", parsed.root_groups.fetch("default")
    %w[../en Devise.en devise..en /en].each do |file|
      assert_raises(ArgumentError) { CatalogYaml.new(file=>"en: {}\n") }
    end
    assert_raises(ArgumentError) { CatalogYaml.new("en"=>"en:\n  hello: Hi\n", "other.en"=>"en:\n  hello: Hello\n") }
    assert_raises(ArgumentError) { CatalogYaml.new("en"=>"en: {}\n", "en.yaml"=>"en: {}\n") }
  end

  test "pending group changes survive synchronization and are accepted on matching merge" do
    sync("en"=>{"en"=>{"account"=>{"name"=>"Name"}}})
    @project.update!(repository: "org/repo")
    root = key("account")
    edit { |w| w.change_key(root.id, name: "account", kind: "branch", file_group: "accounts") }
    sync({"en"=>{"en"=>{"account"=>{"name"=>"Name"}}}}, "unchanged")
    assert_equal "accounts", key("account").payload.file_group
    assert_equal "", CatalogState.new(@project).items.fetch(root.id).payload.file_group
    assert_not @project.catalog_drafts.sole.conflict?
    sync({"accounts.en"=>{"en"=>{"account"=>{"name"=>"Name"}}}}, "merged")
    assert_empty @project.catalog_drafts
    assert_equal "accounts", CatalogState.new(@project).items.fetch(root.id).payload.file_group
  end

  test "snapshot accepts named yml and yaml files and publication retains their extensions" do
    @project.update!(repository: "org/repo", installation_id: 1, git_branch: "main")
    entries = %w[en.yml devise.en.yaml].map { |file| {"path"=>"config/locales/#{file}", "sha"=>file, "size"=>7, "type"=>"blob", "mode"=>"100644"} }
    calls = []
    responder = lambda do |method, path, data = nil|
      calls << [method, path, data]
      case path
      when /commits\/main$/ then @commit
      when /trees\/tree\?recursive=1$/ then {"tree"=>entries}
      when /git\/blobs\// then {"content"=>Base64.strict_encode64("en: {}\n")}
      when /git\/trees$/ then {"sha"=>"new-tree"}
      when /git\/commits$/ then {"sha"=>"new-commit"}
      when /git\/refs$/ then {}
      when /pulls$/ then {"number"=>1}
      else raise "Unexpected API request #{path}"
      end
    end
    CatalogGithub.new(@project).stub(:request, responder) do |api|
      _, files = api.snapshot
      assert_equal %w[en devise.en.yaml], files.keys
      api.publish!(@commit, files.transform_values { "en:\n  name: Name\n" }, files)
    end
    paths = calls.find { |_, path, _| path.end_with?("/git/trees") }.last.fetch(:tree).map { |entry| entry[:path] }
    assert_equal %w[config/locales/en.yml config/locales/devise.en.yaml], paths
  end

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
