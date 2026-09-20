require "test_helper"
class LanguageTableTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
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
end
