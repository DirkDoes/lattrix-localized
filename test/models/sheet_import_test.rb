require "test_helper"

class SheetImportTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Imported project")
    @english = @project.languages.create!(name: "English", identifier: "en", enabled: true)
    @dutch = @project.languages.create!(name: "Dutch", identifier: "nl", enabled: true)
  end

  test "detects JSON parent translations, plurals, wildcards, and omitted values" do
    importer = import("json_parent_plural/en.json", "json_parent_plural/nl.json")

    assert_equal({delimiter: ".", wildcard_format: "${...}", case_sensitive_keys: false,
      allow_parent_translations: true, pluralization_enabled: true, missing_value_behavior: "omit"}, importer.settings)
    assert_equal 23, importer.preview[:translations]

    sheet = @project.sheets.create!(name: "Website", default_language: @english, **importer.settings)
    importer.apply!(sheet: sheet, actor: users(:one))

    keys = sheet.translation_tree.recordings.keys.includes(:recordable)
    assert_equal 16, keys.count
    assert keys.find { |recording| recording.recordable.name == "notifications" }.recordable.pluralized?
    events = RecordingEvent.where(recording: sheet.translation_tree.recordings, change_type: "import")
    assert_equal 39, events.count
    assert_equal 1, events.distinct.count(:change_id)
  end

  test "detects YAML case-sensitive keys and fallback values" do
    importer = import("yaml_case_sensitive_fallback/en.yml", "yaml_case_sensitive_fallback/nl.yml")

    assert_equal({delimiter: ".", wildcard_format: "$[...]", case_sensitive_keys: true,
      allow_parent_translations: false, pluralization_enabled: true, missing_value_behavior: "fallback"}, importer.settings)
    assert_equal 24, importer.preview[:translations]
  end

  test "detects CSV delimiter, omitted values, parent translations, and plurals" do
    importer = import("csv_parent_plural_empty.csv")

    assert_equal({delimiter: "::", wildcard_format: '#{...}', case_sensitive_keys: false,
      allow_parent_translations: true, pluralization_enabled: true, missing_value_behavior: "omit"}, importer.settings)
    assert_equal 17, importer.preview[:translations]
  end

  test "prefers omit for quoted empty CSV values too" do
    importer = import("csv_explicit_empty.csv")

    assert_equal "omit", importer.settings[:missing_value_behavior]
    assert_equal 15, importer.preview[:translations]
  end

  test "reads a real Excel workbook and detects plural and wildcard settings" do
    importer = import("excel_plural_fallback.xlsx")

    assert_equal({delimiter: ".", wildcard_format: "%{...}", case_sensitive_keys: false,
      allow_parent_translations: false, pluralization_enabled: true, missing_value_behavior: "fallback"}, importer.settings)
    assert_equal 18, importer.preview[:translations]
  end

  private

  def import(*fixtures)
    SheetImport.new(project: @project, default_language_id: @english.id, uploads: fixtures.map { |fixture| upload(fixture) })
  end

  def upload(fixture)
    path = file_fixture("sheet_import/#{fixture}")
    ActionDispatch::Http::UploadedFile.new(tempfile: path.open("rb"), filename: path.basename.to_s, type: "application/octet-stream")
  end
end
