require "test_helper"
class LanguageTableTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper
  setup do
    @user=users(:one); @user.update!(role: :owner,email_verified_at:Time.current); sign_in @user
    @project=Project.create!(name:"Language table")
    @one=@project.sheets.create!(name:"One"); @two=@project.sheets.create!(name:"Two")
  end
  test "empty selection means all and selected sheets constrain availability" do
    post project_languages_path(@project),params:{language:{name:"Pirate",identifier:"pirate",sheet_ids:[]}},as: :json
    assert_response :success
    language=@project.languages.sole
    assert @one.active_languages.exists?(id:language.id)
    patch project_language_path(@project,language),params:{language:{name:"Pirate",identifier:"pirate",sheet_ids:[@two.id]}},as: :json
    assert_response :success
    assert_not @one.active_languages.exists?(id:language.id)
    assert @two.active_languages.exists?(id:language.id)
    @two.update!(default_language:language)
    patch project_language_path(@project,language),params:{language:{name:"Pirate",identifier:"pirate",sheet_ids:[@one.id]}},as: :json
    assert_response :unprocessable_entity
    assert @two.active_languages.exists?(id:language.id)
    patch project_language_path(@project,language),params:{language:{name:"Pirate",identifier:"pirate",sheet_ids:[]}},as: :json
    assert_response :success
    assert @one.active_languages.exists?(id:language.id)
    get settings_project_path(@project)
    assert_select 'se-collection se-select[multiple][searchable]'
    assert_select 'se-input[size=small]',count:0
    get settings_project_sheet_path(@project,@one)
    assert_select 'input[name="language_ids[]"]',count:0
  end
  test "settings failure is a single snackbar and parent values are preserved" do
    @one.update!(allow_parent_translations:true)
    language=@project.languages.create!(name:"English",identifier:"en",enabled:true)
    parent=Recording.create_key!(tree:@one.translation_tree,parent:nil,name:"parent")
    Recording.create_key!(tree:@one.translation_tree,parent:parent,name:"child")
    parent.save_translation!(language,"Keep this")
    patch project_sheet_path(@project,@one),params:{sheet:{allow_parent_translations:"0"}}
    assert_response :unprocessable_entity
    assert_select 'se-toast[tone=error]',count:1
    assert_select 'se-text[role=alert]',count:0
    assert @one.reload.allow_parent_translations?
  end

  test "basic language rows edit the default identifier and always show archive" do
    language = @project.languages.create!(name: "English", identifier: "en", enabled: true)

    get settings_project_path(@project)
    assert_select 'se-list-header span', text: "Identifier"
    assert_select 'se-list-row[data-controller=language-row] se-input[data-language-row-target=identifier][value=en]', count: 1
    assert_select 'se-list-row[data-controller=language-row] se-button[icon=archive][aria-label="Archive English"]:not([text])', count: 1

    patch project_language_path(@project, language), params: {language: {name: "English", identifier: "en_GB", sheet_ids: []}}, as: :json
    assert_response :success
    assert_equal "en_gb", language.reload.identifier
    assert_equal "en_gb", @project.identifier_sets.first.language_identifiers.find_by!(language: language).identifier

    @project.update!(advanced_languages: true)
    get settings_project_path(@project)
    assert_select 'se-list-row[data-controller=language-row] se-input[data-language-row-target=identifier]', count: 0
    assert_select 'se-list-row[data-controller=language-row] se-button[icon=archive][aria-label="Archive English"]:not([text])', count: 1
  end

  test "languages archive safely and permanent deletion purges translations and history" do
    language = @project.languages.create!(name: "English", identifier: "en", enabled: true)
    key = Recording.create_key!(tree: @one.translation_tree, parent: nil, name: "hello", actor: @user)
    value = key.save_translation!(language, "Hello", actor: @user)

    patch archive_project_language_path(@project, language)
    assert_redirected_to settings_project_path(@project)
    assert language.reload.archived?
    assert_not @one.active_languages.exists?(language.id)
    assert TextTranslation.exists?(value.recordable_id)
    assert RecordingEvent.exists?(recordable_type: "TextTranslation", recordable_id: value.recordable_id)

    patch restore_project_language_path(@project, language)
    assert language.reload.active?
    assert @one.active_languages.exists?(language.id)

    patch archive_project_language_path(@project, language)
    assert_enqueued_with(job: DeleteLanguageJob) do
      delete project_language_path(@project, language)
    end
    perform_enqueued_jobs
    assert_not Language.exists?(language.id)
    assert_not Recording.exists?(value.id)
    assert_not TextTranslation.exists?(value.recordable_id)
    assert_not RecordingEvent.exists?(recordable_type: "TextTranslation", recordable_id: value.recordable_id)
  end
end
