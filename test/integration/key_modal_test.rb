require "test_helper"
class KeyModalTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  setup do
    @user = users(:one)
    @user.update!(role: :owner, email_verified_at: Time.current)
    @project = Project.create!(name: "Key editor checks")
    @project.project_memberships.create!(user: @user, role: "owner")
    @en = @project.languages.create!(name: "English", identifier: "en", enabled: true)
    @nl = @project.languages.create!(name: "Dutch", identifier: "nl", enabled: true)
    @fr = @project.languages.create!(name: "French", identifier: "fr", enabled: true)
    @sheet = @project.sheets.create!(name: "Main", default_language: @en, allow_parent_translations: true)
    @tree = @sheet.translation_tree
    sign_in @user
  end

  def key(name, parent: nil, values: {})
    Recording.create_key!(tree: @tree, parent: parent, name: name, values: values)
  end

  test "shared modal supports optional rows descriptions and bounded parent lookup" do
    parent = key("account")
    get new_project_sheet_recording_path(@project,@sheet)
    assert_response :success
    assert_select 'se-input[name=description]'
    assert_select '[data-key-editor-target=translations][hidden]'
    assert_select 'se-checkbox[variant=switch][name=pluralized]'
    assert_select 'se-input[name^="translations["]', count: 0
    get new_project_sheet_recording_path(@project,@sheet,parent_id: parent.id)
    assert_select 'se-select[label="Parent key"][searchable][remote]:not([disabled])'
    get preview_project_sheet_recordings_path(@project,@sheet,name: "account.email")
    assert_equal parent.id, response.parsed_body['parent_id']
    assert_equal "email", response.parsed_body['name']
    get preview_project_sheet_recordings_path(@project,@sheet,name: "missing.email")
    assert_equal true, response.parsed_body['valid']
    assert_equal [false, false], response.parsed_body['existing']
    get preview_project_sheet_recordings_path(@project,@sheet,name: "email.name",separated: "1",parent_id: parent.id)
    assert_equal true, response.parsed_body['valid']
    get parents_project_sheet_recordings_path(@project,@sheet,q: "ac")
    assert_empty response.parsed_body
    get parents_project_sheet_recordings_path(@project,@sheet,q: "acc")
    assert_equal [{"id"=>parent.id,"label"=>"account"}], response.parsed_body
  end

  test "dotted creation plural rows descriptions and export omission" do
    parent = key("account")
    post project_sheet_recordings_path(@project,@sheet), params: {name: "account.items", description: "Number of items",pluralized: "1",translation_rows: {"0"=>{language_id: @en.id,text: "Items"}}}, as: :json
    assert_response :success
    item = parent.children.active.keys.sole
    assert_equal "Number of items", item.recordable.description
    forms = item.children.active.keys.includes(:recordable).index_by { |r| r.recordable.name }
    assert_equal TranslationKey::PLURAL_CATEGORIES.sort, forms.keys.sort
    assert_empty item.children.active.texts
    forms['few'].save_translation!(@fr,"Quelques")
    get translations_project_sheet_path(@project,@sheet,left: @en.identifier,right: @nl.identifier)
    assert_select '[data-plural-category=one]:not([hidden])'
    assert_select '[data-plural-category=other]:not([hidden])'
    assert_select '[data-plural-category=few][hidden]'
    assert_select '[data-plural-parent] se-menu',count: 0
    assert_select 'se-tooltip', text: "Number of items"
    assert_select 'se-tooltip > [data-se-region=trigger]'
    get translations_project_sheet_path(@project,@sheet,left: @en.identifier,right: @fr.identifier,view: "tree")
    assert_select '[data-plural-category=few]:not([hidden])'
    @sheet.update!(missing_value_behavior: "empty")
    output = CSV.parse(TranslationExport.new(@sheet).generate("csv"),headers: true)
    assert_equal ["account.items.few","account.items.other"], output.map { |r| r['key'] }.sort
    assert_nil output.find { |r| r['key'] == 'account.items.other' }['nl']
    patch translation_project_sheet_recording_path(@project,@sheet,item), params: {language_id: @en.id,text: "Invalid parent",version: "new"},as: :json
    assert_response :unprocessable_entity
    delete project_sheet_recording_path(@project,@sheet,forms['one']),params: {version: forms['one'].lock_version},as: :json
    assert_response :unprocessable_entity
    @sheet.update!(pluralization_enabled: false)
    get translations_project_sheet_path(@project,@sheet)
    assert_select '[data-plural-parent]',count: 0
    assert_select 'se-list-row[data-key-row]',count: 8
  end

  test "an existing translated key can be made plural" do
    item = key("features", values: {@en => "Features", @nl => "Functies", @fr => "Fonctionnalités"})
    values = item.children.active.texts.includes(:recordable).index_by { |value| value.recordable.language_id }
    get edit_project_sheet_recording_path(@project, @sheet, item)
    assert_select "se-modal > se-button[data-se-region=footer][data-modal-action=confirm][text='Save key']"
    assert_select "form[data-key-form-plural-confirmation-value=true]"
    assert_select "se-modal[data-confirm-plural-form]", text: /features.*features\.other/
    assert_select "form se-modal[data-confirm-plural-form]", count: 0
    assert_select "input[data-key-editor-target=initial]", count: 1

    rows = values.transform_values { |value| {language_id: value.recordable.language_id, text: value.recordable.text, version: value.lock_version, translation_id: value.id} }
    patch project_sheet_recording_path(@project, @sheet, item), params: {name: "features", version: item.lock_version, pluralized: "1", translation_rows: rows}, as: :json

    assert_response :success
    assert item.reload.recordable.pluralized?
    assert_empty item.children.active.texts
    other = item.children.active.keys.includes(:recordable).find { |child| child.recordable.name == "other" }
    assert_equal 3, other.children.active.texts.count
  end

  test "disabling plurals prunes only empty optional forms" do
    item = key("items")
    item.set_pluralized!(true)
    forms = item.children.active.keys.includes(:recordable).index_by { |child| child.recordable.name }
    forms.fetch("few").save_translation!(@en, "A few")
    item.set_pluralized!(false)

    assert_equal %w[few one other], item.children.active.keys.includes(:recordable).map { |child| child.recordable.name }.sort
    assert forms.fetch("zero").reload.deleted_at?
    assert_equal "deleted", forms.fetch("zero").recording_events.last.action
  end

  test "edit translation concurrency rolls back structural changes and conversion conflicts preserve values" do
    item = key("item",values: {@en=>"Old"})
    value = item.children.active.texts.sole
    item.save_translation!(@en,"Someone else")
    patch project_sheet_recording_path(@project,@sheet,item),params: {name: "renamed",version: item.lock_version,description: "New description",pluralized: "1",translation_rows: {"0"=>{language_id:@en.id,text:"My edit",version:value.lock_version,translation_id:value.id}}},as: :json
    assert_response :unprocessable_entity
    assert_equal "item",item.reload.recordable.name
    assert_equal "Someone else",value.reload.recordable.text
    other = key("other",parent: item,values: {@en=>"Existing other"})
    patch pluralization_project_sheet_recording_path(@project,@sheet,item),params: {version:item.lock_version,enabled:"1"},as: :json
    assert_response :unprocessable_entity
    assert_not item.reload.recordable.pluralized
    assert_equal "Someone else",value.reload.recordable.text
    assert_equal "Existing other",other.children.active.texts.sole.recordable.text
  end

  test "shared edit form can change language or remove and replace a translation" do
    item = key("label", values: {@en=>"Hello"})
    value = item.children.active.texts.sole
    patch project_sheet_recording_path(@project,@sheet,item),params: {name:"label",version:item.lock_version,translation_rows:{"0"=>{language_id:@nl.id,text:"Hallo",version:value.lock_version,translation_id:value.id}}},as: :json
    assert_response :success
    current = item.children.active.texts.sole
    assert_equal @nl.id,current.recordable.language_id
    assert_equal "Hallo",current.recordable.text
    patch project_sheet_recording_path(@project,@sheet,item),params: {name:"label",version:item.reload.lock_version,translation_rows:{"0"=>{language_id:@nl.id,text:"",version:current.lock_version,translation_id:current.id},"1"=>{language_id:@nl.id,text:"Hoi",version:"new"}}},as: :json
    assert_response :success
    assert_equal "Hoi",item.children.active.texts.sole.recordable.text
  end

  test "delimiter changes validate active key names and apply to paths and exports" do
    parent = key("account")
    conflict = key("bad/name")
    patch project_sheet_path(@project,@sheet),params: {sheet: {delimiter:"/"}}
    assert_response :unprocessable_entity
    assert_select 'se-modal[title="Cannot change delimiter"][open]'
    assert_equal ".",@sheet.reload.delimiter
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new:true) { @sheet.update_columns(delimiter:"/") }
    end
    conflict.discard_subtree!(expected:conflict.lock_version)
    patch project_sheet_path(@project,@sheet),params: {sheet: {delimiter:"/"}}
    assert_response :redirect
    assert_equal "/",@sheet.reload.delimiter
    get preview_project_sheet_recordings_path(@project,@sheet,name:"account/email")
    assert_equal ["account","email"],response.parsed_body['levels']
    post project_sheet_recordings_path(@project,@sheet),params: {name:"account/email",translations:{@en.id=>"Email"}},as: :json
    assert_response :success
    assert_includes @tree.key_rows.map { |row| row['path'] },"account/email"
    assert_includes TranslationExport.new(@sheet).generate("csv"),"account/email"
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new:true) { key("invalid/name") }
    end
    get settings_project_sheet_path(@project,@sheet)
    assert_select '.app-settings-body'
    assert_select 'se-button[aria-label="About plural editor"]'
    assert_select 'se-list-row > span', text:'Plural categories',count:0
    assert response.body.index('/assets/theme-') < response.body.index('rel="stylesheet"')
  end

  test "settings switches allow no default and reenable plural interpretation safely" do
    get settings_project_sheet_path(@project,@sheet)
    assert_select '.app-settings-body se-checkbox[variant=switch]', count: 3
    assert_select 'se-input[name="sheet[plural_categories]"]',count: 0
    patch project_sheet_path(@project,@sheet),params: {sheet: {default_language_id:""}}
    assert_response :redirect
    assert_nil @sheet.reload.default_language_id
    assert TranslationExport.new(@sheet).generate("csv").start_with?("key")
    item = key("items")
    item.set_pluralized!(true)
    @sheet.update!(pluralization_enabled:false)
    item.save_translation!(@en,"Parent value")
    patch project_sheet_path(@project,@sheet),params: {sheet: {pluralization_enabled:"1"}}
    assert_response :redirect
    assert_empty item.children.active.texts
    other = item.children.active.keys.includes(:recordable).find { |r| r.recordable.name == 'other' }
    assert_equal "Parent value",other.children.active.texts.sole.recordable.text
  end
  test "linked paths preview and atomically create missing ancestors" do
    root = key("account")
    get preview_project_sheet_recordings_path(@project,@sheet,name:"account.billing.address")
    assert_equal [true,false,false],response.parsed_body['existing']
    assert_equal ["account","billing","address"],response.parsed_body['levels']
    assert_no_difference('@tree.recordings.count') do
      post project_sheet_recordings_path(@project,@sheet),params:{name:"account.new.invalid",translations:{"missing-language"=>"No"}},as: :json
      assert_response :unprocessable_entity
    end
    post project_sheet_recordings_path(@project,@sheet),params:{name:"account.billing.address"},as: :json
    assert_response :success
    assert_includes @tree.key_rows.map { |r| r['path'] },"account.billing.address"
    get preview_project_sheet_recordings_path(@project,@sheet,name:"ACCOUNT.BILLING.ADDRESS")
    assert_equal false,response.parsed_body['valid']
    assert_match /already exists/,response.parsed_body['error']
    get edit_project_sheet_recording_path(@project,@sheet,root)
    assert_select 'se-modal[title="Remove this subtree?"]',count:0
    get edit_project_sheet_recording_path(@project,@sheet,root,remove:1)
    assert_select 'se-modal[title="Remove this subtree?"]',count:1
  end

  test "translator menus only reveal plural categories" do
    key("ordinary")
    plural = key("items"); plural.set_pluralized!(true)
    translator = users(:two)
    translator.update!(role: :guest,email_verified_at:Time.current)
    @project.project_memberships.create!(user:translator,role:"translator")
    sign_in translator
    get translations_project_sheet_path(@project,@sheet)
    assert_response :success
    assert_select 'se-menu[label="Actions for ordinary"]',count:0
    assert_select 'se-menu[label="Actions for items"]' do |menus|
      actions=JSON.parse(menus.first['options']).filter_map { |option| option['id'] }
      assert_equal ['plural'],actions.uniq
    end
    get edit_project_sheet_recording_path(@project,@sheet,plural,remove:1)
    assert_response :forbidden
  end

  test "relative paths create ancestors and reject whitespace" do
    parent = key("account")
    post project_sheet_recordings_path(@project,@sheet),params:{parent_id:parent.id,separated:"1",name:"profile.email"},as: :json
    assert_response :success
    assert_includes @tree.key_rows.map { |r| r['path'] }, "account.profile.email"
    ["has space", "tab\there", " leading", "line\nbreak"].each do |name|
      post project_sheet_recordings_path(@project,@sheet),params:{name:name},as: :json
      assert_response :unprocessable_entity
      assert_match /whitespace/,response.parsed_body['error']
      assert_not TranslationKey.new(name:name).valid?
    end
  end

  test "defaults and parent visibility match the selected view" do
    fresh = @project.sheets.create!(name:"Fresh")
    assert_not fresh.allow_parent_translations?
    assert_not fresh.case_sensitive_keys?
    assert_equal ".",fresh.delimiter
    assert fresh.pluralization_enabled?
    assert_equal "omit",fresh.missing_value_behavior
    assert_equal "",fresh.wildcard_format
    assert fresh.update(wildcard_format: '$[...]')
    assert_not fresh.update(wildcard_format: '$[]')
    @sheet.update!(allow_parent_translations:false)
    parent = key("account"); child = key("email",parent:parent)
    plural = key("items"); plural.set_pluralized!(true)
    get translations_project_sheet_path(@project,@sheet,view:"keys")
    assert_select "se-list-row[data-key-row='#{parent.id}']",count:0
    assert_select "se-list-row[data-key-row='#{child.id}']",count:1
    assert_select "se-list-row[data-key-row='#{plural.id}']",count:1
    get translations_project_sheet_path(@project,@sheet,view:"tree")
    assert_select "se-list-row[data-key-row='#{parent.id}'] .translation-value",text:'—',count:2
    get preview_project_sheet_recordings_path(@project,@sheet,name:"account.new.deep")
    assert_equal parent.id,response.parsed_body['parent_id']
    assert_equal [true,false,false],response.parsed_body['existing']
  end

  test "sheet wildcard format can be configured or disabled" do
    patch project_sheet_path(@project, @sheet), params: {sheet: {wildcard_format: '$[...]'}}
    assert_redirected_to settings_project_sheet_path(@project, @sheet)
    assert_equal '$[...]', @sheet.reload.wildcard_format
    patch project_sheet_path(@project, @sheet), params: {sheet: {wildcard_format: '$[]'}}
    assert_response :unprocessable_entity
    assert_select 'se-input[name="sheet[wildcard_format]"][error]'
    patch project_sheet_path(@project, @sheet), params: {sheet: {wildcard_format: ''}}
    assert_redirected_to settings_project_sheet_path(@project, @sheet)
    assert_equal '', @sheet.reload.wildcard_format
  end

end
