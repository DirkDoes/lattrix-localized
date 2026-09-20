require "test_helper"
class TranslatorTableTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  setup do
    @user=users(:one); @user.update!(email_verified_at:Time.current, role: :member)
    @project=Project.create!(name:"Translator table")
    @membership=@project.project_memberships.create!(user:@user,role:"translator")
    @en=@project.languages.create!(name:"English",identifier:"en",enabled:true)
    @nl=@project.languages.create!(name:"Dutch",identifier:"nl",enabled:true)
    @sheet=@project.sheets.create!(name:"Words",default_language:@en)
    @membership.membership_languages.create!(language:@nl)
    key=Recording.create_key!(tree:@sheet.translation_tree,parent:nil,name:"items")
    key.set_pluralized!(true)
    sign_in @user
  end
  test "identifiers select columns and permissions control plural menus and icons" do
    @project.identifier_sets.first.language_identifiers.find_by!(language:@nl).update!(identifier:"nl_NL")
    get translations_project_sheet_path(@project,@sheet)
    assert_select 'se-list-header se-select[data-language-side=left][value=en]'
    assert_select 'se-list-header se-select[data-language-side=right][value=nl_NL]'
    assert_select 'se-list-header se-select' do |fields|
      options=JSON.parse(fields.first['options']).index_by { |item| item['id'] }
      assert_equal 'lock',options['en']['icon']
      assert_equal 'pencil',options['nl_NL']['icon']
    end
    assert_select 'se-menu[data-key]' do |menus|
      options=JSON.parse(menus.first['options'])
      assert_not options.any? { |item| item['separator'] || %w[edit child remove].include?(item['id']) }
    end
    get translations_project_sheet_path(@project,@sheet,left:'nl_NL',right:'en')
    assert_select 'se-list-header se-select[data-language-side=left][value=nl_NL]'
    @membership.update!(role:'viewer')
    get translations_project_sheet_path(@project,@sheet)
    assert_select 'se-menu[data-key]',count:0
  end
  test "assignments are a multiselect and empty really denies editing" do
    admin=users(:two); admin.update!(role: :owner,email_verified_at:Time.current); sign_in admin
    get edit_project_project_membership_path(@project,@membership)
    assert_select 'se-select[multiple][name="language_ids[]"]'
    assert_select 'se-checkbox[name="language_ids[]"]',count:0
    patch project_project_membership_path(@project,@membership),params:{project_membership:{role:'translator'},language_ids:['']}
    assert_response :redirect
    assert_empty @membership.reload.languages
    assert_not SheetPolicy.new(@user,@sheet).edit_language?(@nl)
    @membership.update!(role:'viewer')
    get edit_project_project_membership_path(@project,@membership)
    assert_select '[data-membership-languages-target=assignments][hidden]'
  end
  test "initial and later batches are twenty and refresh retains loaded range" do
    45.times { |n| Recording.create_key!(tree:@sheet.translation_tree,parent:nil,name:"word#{n}") }
    get translations_project_sheet_path(@project,@sheet,q:'word')
    assert_select '[data-row-position]',count:20
    assert_select 'turbo-frame[loading=lazy]' do |frames|
      assert_includes frames.first['src'],'left=en'
      assert_includes frames.first['src'],'right=nl'
    end
    get translations_project_sheet_path(@project,@sheet,q:'word',after:20,revision:@sheet.translation_tree.reload.revision)
    assert_select 'turbo-stream[action=append] [data-row-position]',count:20
    get translations_project_sheet_path(@project,@sheet,q:'word',loaded:40)
    assert_select '[data-row-position]',count:40
  end
end
