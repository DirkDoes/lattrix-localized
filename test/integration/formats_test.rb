require "test_helper"

class FormatsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current, role: :member)
    sign_in @user
  end

  test "export showcase lists formats sample translations and generated files" do
    get import_export_path
    assert_response :success
    assert_select "se-sidebar-button[href=?][active]", import_export_path
    assert_select "se-nav-tabs[value=export]"
    assert_select "turbo-frame#format-showcase"
    assert_select "se-list-header", text: /Key.*English.*Dutch/
    assert_select "se-list-row[collapsible] se-badge[text=Plural]"
    assert_select "se-code", text: "account.profile"
    assert_select "se-text[data-controller=wildcard-highlight][data-wildcard-highlight-format-value='${...}']", text: "${count} notifications"
    assert_select "se-code-editor[readonly][autosize][language=yaml]", count: 2
    assert_select ".format-preview-file > se-code", text: "en.yaml"
    assert_select ".format-preview-file > se-code", text: "nl.yaml"
    assert_select "se-code-editor[language=yaml][value*='checkout:']", count: 1
  end

  test "preview supports json csv excel settings and the import placeholder" do
    get import_export_path, params: { export_format: "json", pluralization: "0", parent_translations: "0", missing_value_behavior: "empty" }
    assert_select "se-list-row[collapsible]", count: 0
    assert_select "se-list-row se-code", text: "account.notifications", count: 0
    assert_select "se-list-row se-code", text: "account.notifications.one", count: 1
    assert_select "se-code", text: "account.profile"
    assert_select "se-code-editor[readonly][language=json]", count: 2
    assert_select "se-code-editor[value*='\"pay\": \"\"']"
    assert_select "se-modal#format-settings-modal se-input", count: 0

    get import_export_path, params: { export_format: "json", missing_value_behavior: "omit" }
    assert_select "se-text.translation-empty", text: "—"

    get import_export_path, params: { export_format: "csv" }
    assert_select ".format-preview-file > se-code", text: "translations.csv"
    assert_select ".format-preview-files--single se-code-editor[readonly][language=csv]", count: 1

    get import_export_path, params: { export_format: "xlsx" }
    assert_select "se-card", text: /Excel preview unavailable/
    assert_select "se-code-editor", count: 0

    get import_export_path, params: { tab: "import" }
    assert_select "se-nav-tabs[value=import]"
    assert_select "se-empty-illustration[title='Import formats are coming later']"
  end
end
