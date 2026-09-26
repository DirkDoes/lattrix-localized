require "test_helper"

class SheetImportFlowTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @user.update!(role: :owner, email_verified_at: Time.current)
    sign_in @user
    @project = Project.create!(name: "Import flow")
    @english = @project.languages.create!(name: "English", identifier: "en", enabled: true)
    @dutch = @project.languages.create!(name: "Dutch", identifier: "nl", enabled: true)
  end

  test "CSV preview and creation use the same detected settings and plural structure" do
    post import_preview_project_sheets_path(@project), params: {
      default_language_id: @english.id,
      imports: [fixture_file_upload("sheet_import/csv_parent_plural_empty.csv", "text/csv")]
    }
    assert_response :success
    settings = response.parsed_body.fetch("settings")
    assert_equal true, settings.fetch("pluralization_enabled")
    assert_equal true, settings.fetch("allow_parent_translations")
    assert_equal "omit", settings.fetch("missing_value_behavior")
    assert_equal "::", settings.fetch("delimiter")

    post project_sheets_path(@project), params: {
      sheet: {name: "Catalog", default_language_id: @english.id},
      imports: [fixture_file_upload("sheet_import/csv_parent_plural_empty.csv", "text/csv")]
    }
    sheet = @project.sheets.find_by!(name: "Catalog")
    assert_redirected_to project_sheet_path(@project, sheet)
    assert sheet.pluralization_enabled?
    assert sheet.allow_parent_translations?
    assert_equal "::", sheet.delimiter
    assert_equal "omit", sheet.missing_value_behavior

    keys = sheet.translation_tree.recordings.active.keys.includes(:recordable)
    items = keys.find { |recording| recording.recordable.name == "items" }
    note = keys.find { |recording| recording.recordable.name == "note" }
    assert items.recordable.pluralized?
    assert note.children.active.texts.joins("JOIN text_translations ON text_translations.id = recordings.recordable_id").where(text_translations: {language_id: @english.id}).exists?
    assert_not note.children.active.texts.joins("JOIN text_translations ON text_translations.id = recordings.recordable_id").where(text_translations: {language_id: @dutch.id}).exists?
  end
end
