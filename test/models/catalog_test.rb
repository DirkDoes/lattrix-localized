require "test_helper"

class CatalogTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Catalog", source_locale: "en")
    @project.languages.create!(identifier: "nl")
    @writer = CatalogWriter.new(@project)
  end
  def edit(&block) = @writer.edit(expected: @project.reload.revision, &block)
  def key(path) = CatalogState.new(@project, pending: true).keys.find { |k| CatalogState.new(@project, pending: true).path(k) == path }
  def exported = CatalogExport.new(@project).values

  test "scalar placeholders preserve last accepted translation until draft is valid" do
    edit { |w| w.add_key("greeting") }
    edit { |w| w.translate(key("greeting").id, "en", "Hello %{name}") }
    edit { |w| w.translate(key("greeting").id, "nl", "Hallo %{name}") }
    edit { |w| w.translate(key("greeting").id, "nl", "Hallo") }
    assert_equal "Hallo %{name}", exported.dig("nl", "greeting")
    assert_equal 1, @project.catalog_drafts.count
    edit { |w| w.translate(key("greeting").id, "nl", "Welkom %{name}") }
    assert_equal "Welkom %{name}", exported.dig("nl", "greeting")
    assert_empty @project.catalog_drafts
  end

  test "plural group publishes atomically and count is required only in other few many" do
    edit { |w| w.add_key("items", kind: "plural") }
    edit { |w| w.translate(key("items.one").id, "en", "One item") }
    assert_nil exported["en"]
    edit { |w| w.translate(key("items.other").id, "en", "%{count} items") }
    assert_equal({"items.one"=>"One item", "items.other"=>"%{count} items"}, exported["en"])
    edit { |w| w.translate(key("items.other").id, "en", "Items") }
    assert_equal "%{count} items", exported.dig("en", "items.other")
  end

  test "restore is inclusive with backward deltas across moves and deletes" do
    edit { |w| w.add_key("name") }
    edit { |w| w.translate(key("name").id, "en", "Name") }
    position = @project.catalog_events.maximum(:id)
    edit { |w| w.move(key("name").id, "name.other") }
    edit { |w| w.remove(key("name").id) }
    assert_empty exported
    @writer.restore(position, expected: @project.reload.revision)
    assert_equal({"en"=>{"name"=>"Name"}}, exported, CatalogState.new(@project).items.transform_values(&:signature).inspect + @project.catalog_drafts.map(&:attributes).inspect)
    assert_equal "restore", @project.catalog_change_sets.last.origin
    assert_equal({"en"=>{"name"=>"Name"}}, CatalogExport.new(@project, state: CatalogState.new(@project, at: position)).values)
  end

  test "stale edits do not mutate the catalog" do
    revision = @project.revision
    edit { |w| w.add_key("name") }
    assert_raises(ActiveRecord::StaleObjectError) { @writer.edit(expected: revision) { |w| w.add_key("bad") } }
    assert_nil key("bad")
  end

  test "yaml strings only and locale wrapper only in yaml" do
    yaml = CatalogYaml.new("en"=>"en:\n  name: Name\n  amount: 3\n  items: [one, two]\n  enabled: true\n")
    assert_equal({"name"=>"Name"}, yaml.values["en"])
    edit { |w| w.add_key("name") }
    edit { |w| w.translate(key("name").id, "en", "Name") }
    assert_equal({"en"=>{"name"=>"Name"}}, YAML.safe_load(CatalogExport.new(@project).files["en"]))
    assert_includes CatalogExport.new(@project).download("csv").first, "name,Name"
  end

  test "github conflicts retain authoritative value and preserve draft" do
    CatalogReconcile.new(@project, {"en"=>"en:\n  name: Name\n"}, sha: "first").apply!
    @project.update!(repository: "example/test")
    edit { |w| w.translate(key("name").id, "en", "Local") }
    CatalogReconcile.new(@project, {"en"=>"en:\n  name: Remote\n"}, sha: "second").apply!
    assert_equal "Remote", exported.dig("en", "name")
    assert @project.catalog_drafts.first.conflict?
    assert_equal "Remote", CatalogState.new(@project, pending: true).translation(key("name").id, "en").payload.value
  end

  test "invalid authoritative state preserves previous accepted projection" do
    CatalogReconcile.new(@project, {"en"=>"en:\n  name: Name\n"}, sha: "first").apply!
    assert_raises(ArgumentError) { CatalogReconcile.new(@project, {"en"=>"en:\n  name: '%{count}'\n"}, sha: "bad").apply! }
    assert_equal "Name", exported.dig("en", "name")
    assert @project.reload.sync_error.present?
  end

  test "source placeholder changes wait for dependent translations" do
    edit { |w| w.add_key("hello") }
    edit { |w| w.translate(key("hello").id, "en", "Hi %{name}"); w.translate(key("hello").id, "nl", "Hoi %{name}") }
    edit { |w| w.translate(key("hello").id, "en", "Hi %{username}") }
    assert_equal "Hi %{name}", exported.dig("en", "hello")
    edit { |w| w.translate(key("hello").id, "nl", "Hoi %{username}") }
    assert_equal "Hi %{username}", exported.dig("en", "hello")
    assert_empty @project.catalog_drafts
  end

  test "unpluralizing prunes empty categories but preserves translated categories" do
    @project.languages.create!(identifier: "ar")
    edit { |w| w.add_key("items", kind: "plural") }
    edit { |w| w.translate(key("items.one").id, "en", "One"); w.translate(key("items.other").id, "en", "%{count} things") }
    edit { |w| w.change_key(key("items").id, name: "items", kind: "branch") }
    assert_nil key("items.few")
    assert_nil key("items.zero")
    assert key("items.one")
    assert key("items.other")
    assert_equal "branch", key("items").payload.kind
  end

  test "plural ordinary placeholders warn rather than block" do
    edit { |w| w.add_key("items", kind: "plural") }
    edit do |w|
      w.translate(key("items.one").id, "en", "%{name} has one")
      w.translate(key("items.other").id, "en", "%{name} has %{count}")
      w.translate(key("items.one").id, "nl", "Een")
      w.translate(key("items.other").id, "nl", "%{count} dingen")
    end
    assert_equal "%{count} dingen", exported.dig("nl", "items.other")
    assert CatalogState.new(@project).warnings(key("items.other"), "nl").any?
  end
end
