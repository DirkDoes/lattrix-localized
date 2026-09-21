require "test_helper"
require "zip"
require "csv"
class ExportsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  setup do
    @user = users(:one)
    @user.update!(role: :owner, email_verified_at: Time.current)
    sign_in @user
    @project = Project.create!(name: "Export check")
    @en = @project.languages.create!(name: "English", identifier: "en", enabled: true)
    @nl = @project.languages.create!(name: "Dutch", identifier: "nl", enabled: true)
    @sheets = %w[Website Mobile].map do |name|
      sheet = @project.sheets.create!(name: name)
      key = Recording.create_key!(tree: sheet.translation_tree, parent: nil, name: "hello")
      key.save_translation!(@en, "Hello")
      key.save_translation!(@nl, "Hallo")
      sheet
    end
  end
  teardown do
    @project.export_requests.each { |request| FileUtils.rm_f(request.path) }
  end
  def build(format, sheets: [@sheets.first.id], languages: [], **extra)
    post project_exports_path(@project), params: {export_format: format, sheet_ids: sheets, language_ids: languages}.merge(extra), as: :json
    assert_response :success
    request = @project.export_requests.order(:created_at).last
    ExportJob.perform_now(request.id)
    assert_equal "ready", request.reload.status, request.error
    request
  end
  def entries(request)
    Zip::File.open(request.path) { |zip| zip.map(&:name) }
  end
  test "format packaging and identifier sets" do
    set = @project.identifier_sets.first
    set.language_identifiers.find_by!(language: @en).update!(identifier: "en_US")
    single = build("json", languages: [@en.id])
    assert_equal "en_US.json", single.filename
    assert_equal({"hello" => "Hello"}, JSON.parse(File.read(single.path)))
    assert_equal %w[en_US.yaml nl.yaml], entries(build("yaml")).sort
    multi = build("json", sheets: @sheets.map(&:id))
    assert_equal %w[mobile/en_US.json mobile/nl.json website/en_US.json website/nl.json], entries(multi).sort
    csv = build("csv", descriptions: "1")
    assert_equal "website.csv", csv.filename
    assert_equal %w[key description nl en_US], CSV.read(csv.path).first
    assert_equal %w[mobile.csv website.csv], entries(build("csv", sheets: @sheets.map(&:id))).sort
    excel = build("xlsx", sheets: @sheets.map(&:id), descriptions: "1")
    assert_equal "export_check.xlsx", excel.filename
    assert_equal 2, entries(excel).grep(%r{xl/worksheets/sheet\d.xml}).length
    Zip::File.open(excel.path) do |zip|
      xml = zip.read("xl/worksheets/sheet1.xml")
      assert_includes xml, "description"
      assert_includes xml, "Hallo"
    end
  end
  test "cancelled jobs do not produce files and sessions cannot take downloads" do
    post project_exports_path(@project), params: {export_format: "csv"}, as: :json
    assert_response :success
    url = response.parsed_body.fetch("url")
    request = @project.export_requests.last
    assert_no_difference("ExportRequest.count") do
      post project_exports_path(@project), params: {export_format: "json"}, as: :json
      assert_equal url, response.parsed_body.fetch("url")
    end
    delete url
    assert_response :no_content
    ExportJob.perform_now(request.id)
    assert_equal "cancelled", request.reload.status
    assert_not request.path.exist?
    ready = build("csv")
    reset!
    sign_in @user
    get download_project_export_path(@project, ready)
    assert_response :not_found
  end
  test "selections must belong to the project and download access is rechecked" do
    foreign = Project.create!(name: "Other").sheets.create!(name: "Private")
    post project_exports_path(@project), params: {export_format: "csv", sheet_ids: [foreign.id]}, as: :json
    assert_response :unprocessable_entity
    ready = build("csv")
    users(:two).update!(role: :owner, email_verified_at: Time.current)
    @user.update!(role: :guest)
    assert_raises(Pundit::NotAuthorizedError) { ready.accessible_sheets }
  end
  test "advanced settings preserve mappings and delimiters allow up to three characters" do
    post project_identifier_sets_path(@project), params: {identifier_set: {name: "Java", description: "Java identifiers"}}, as: :json
    assert_response :success
    assert_equal 2, @project.identifier_sets.last.language_identifiers.count
    post project_languages_path(@project), params: {language: {name: "Pirate", sheet_ids: []}}, as: :json
    assert_response :success
    assert_equal 2, @project.languages.find_by!(name: "Pirate").language_identifiers.count
    @project.update!(advanced_languages: true)
    get settings_project_path(@project)
    assert_response :success
    assert_select 'se-list-row[variant=secondary]', count: 6
    @project.update!(advanced_languages: false)
    assert_equal 6, LanguageIdentifier.joins(:identifier_set).where(identifier_sets: {project_id: @project.id}).count
    assert @sheets.first.update(delimiter: "::")
    assert_not @sheets.first.update(delimiter: "....")
  end

  test "exports a sheet at a history point" do
    sheet = @sheets.first
    value = sheet.translation_tree.recordings.active.texts.includes(:recordable).find { |recording| recording.recordable.language_id == @en.id }
    event = value.recording_events.sole
    value.parent.save_translation!(@en, "Hi")

    request = build("csv", recording_event_id: event.id)
    assert_equal "Hello", CSV.read(request.path, headers: true).first["en"]
  end
end
