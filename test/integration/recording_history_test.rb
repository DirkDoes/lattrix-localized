require "test_helper"

class RecordingHistoryTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner = users(:two)
    @owner.update!(role: :owner, email_verified_at: Time.current)
    @translator = users(:one)
    @translator.update!(role: :member, email_verified_at: Time.current)
    @project = Project.create!(name: "History page")
    @project.project_memberships.create!(user: @owner, role: "owner")
    @membership = @project.project_memberships.create!(user: @translator, role: "translator")
    @language = @project.languages.create!(name: "English", identifier: "en", enabled: true)
    @membership.membership_languages.create!(language: @language)
    @french = @project.languages.create!(name: "French", identifier: "fr", enabled: true)
    @sheet = @project.sheets.create!(name: "Words", default_language: @language)
    @key = Recording.create_key!(tree: @sheet.translation_tree, parent: nil, name: "greeting", actor: @owner)
    @value = @key.save_translation!(@language, "Hello", actor: @owner)
    @old_event = @value.recording_events.sole
    @key.save_translation!(@language, "Hi", actor: @owner)
  end

  test "translator sees history without sheet restore controls" do
    sign_in @translator
    get history_project_sheet_path(@project, @sheet, language_ids: [ @language.id ])
    assert_response :success
    assert_select "se-profile[name='#{@owner.name}'][subtitle$='ago']"
    assert_select "se-text.history-mobile-actor[layout-mode='mobile-only']", text: /#{@owner.name}.*·.*ago/
    assert_select "se-popover[icon='funnel'][icon-only]"
    assert_select "se-select[name='language_ids'][multiple]"
    assert_select "se-checkbox[name='types[]'][checked]", count: 2
    assert_select "details", count: 0
    assert_select ".history-description", text: /translation for/
    assert_select ".history-values", text: /Hello.*→.*Hi/
    actor_options = JSON.parse(css_select("se-select[name='actor_ids']").sole["options"])
    assert_equal [ @owner.name ], actor_options.pluck("label")
    assert_not_includes response.body, @owner.email
    assert_select "form[action*='recording_events']", count: 0
    patch restore_project_sheet_recording_event_path(@project, @sheet, @old_event)
    assert_response :forbidden
  end

  test "owner restores every later sheet change regardless of language filter" do
    french_value = @key.save_translation!(@french, "Bonjour", actor: @owner)
    sign_in @owner
    get history_project_sheet_path(@project, @sheet)
    assert_select "se-badge[tone='important'][text='English']"
    assert_select "se-badge[tone='important'][text='French']"
    newest_event = french_value.recording_events.order(:created_at, :id).last
    newest_options = JSON.parse(css_select("se-menu[data-event-id='#{newest_event.id}']").sole["options"])
    old_options = JSON.parse(css_select("se-menu[data-event-id='#{@old_event.id}']").sole["options"])
    assert_equal [ "export" ], newest_options.pluck("id")
    assert_equal %w[restore export], old_options.pluck("id")
    assert_equal "Restore sheet to this point", old_options.first.fetch("label")
    assert_select "se-modal#restore-event-#{@old_event.id}", text: /reverse 2 later events/

    get history_project_sheet_path(@project, @sheet, language_ids: [ @language.id ])
    assert_response :success
    assert_select "se-badge[tone='important'][text='English']"
    assert_select "se-badge[text='French']", count: 0
    assert_select "se-tooltip[content*='entire sheet']", count: 0

    patch restore_project_sheet_recording_event_path(@project, @sheet, @old_event), params: { language_ids: [ @language.id ] }
    assert_redirected_to history_project_sheet_path(@project, @sheet, language_ids: [ @language.id.to_s ])
    assert_equal "Hello", @value.reload.recordable.text
    assert french_value.reload.deleted_at?

    restore_events = RecordingEvent.where(change_type: "revert")
    get history_project_sheet_path(@project, @sheet)
    assert_select "se-list-row[data-change-id='#{restore_events.first.change_id}'][level='0'][collapsible][collapsed]", count: 1
    assert_select "se-list-row[level='1'][guides][variant='secondary']", count: restore_events.count
    assert_select "se-list-row[level='1'] .history-event-detail", count: restore_events.count
    assert_select "se-list-row[level='1'] .history-actor", count: 0
    assert_select ".history-event-detail", text: /Reverted change to translation/
    assert_select ".history-event-detail", text: /Reverted creation of translation/
  end

  test "type and actor filters limit history" do
    sign_in @translator
    get history_project_sheet_path(@project, @sheet, language_ids: [ @language.id ], types: [ "translation" ], actor_ids: [ @owner.id ])
    assert_response :success
    assert_select "se-checkbox[name='types[]'][checked]", count: 1
    assert_select ".history-description", text: /translation for/
    assert_select ".history-description", text: /translation key/, count: 0
  end

  test "key update rows derive name description and pluralization changes from recordables" do
    @key.change_key!(name: "welcome", parent_id: @key.parent_id, description: "Shown on the home page", expected: @key.lock_version, actor: @owner)
    @key.set_pluralized!(true, actor: @owner)
    sign_in @owner

    get history_project_sheet_path(@project, @sheet, types: ["key"])

    assert_select ".history-description", text: /Changed translation key.*welcome.*Key.*greeting.*welcome.*Description.*—.*Shown on the home page/
    assert_select ".history-description", text: /Changed translation key.*welcome.*Pluralization.*Off.*On/
  end

  test "large restore groups load ten events then twenty at a time" do
    11.times { |index| Recording.create_key!(tree: @sheet.translation_tree, parent: nil, name: "later_#{index}", actor: @owner) }
    assert_equal 12, @old_event.restore_sheet!(actor: @owner)
    change_id = RecordingEvent.where(change_type: "revert").pick(:change_id)
    sign_in @owner

    get history_project_sheet_path(@project, @sheet)
    assert_response :success
    assert_select "se-list-row[data-change-id='#{change_id}']", text: /12 events/
    assert_select "se-list-row[level='1'] .history-event-detail:not(.history-more)", count: 10
    assert_select "se-list-row#history-more-#{change_id} se-button[text='Load 20 more']", count: 1

    get change_project_sheet_recording_events_path(@project, @sheet, format: :turbo_stream), params: { change_id: change_id, offset: 10 }, headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_select "turbo-stream[action='before'][target='history-more-#{change_id}'] se-list-row[level='1']", count: 2
    assert_select "turbo-stream[action='replace'][target='history-more-#{change_id}'] se-list-row", count: 0
  end

  test "viewers cannot see history" do
    @membership.update!(role: "viewer")
    sign_in @translator
    get history_project_sheet_path(@project, @sheet)
    assert_response :forbidden
  end
end
