require "test_helper"
class TranslationEditorTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  def export_entry(name)
    content = nil
    Zip::File.open_buffer(@export_data) { |archive| content = archive.read(name) }
    content
  end
  setup do
    @user=users(:one)
    @user.update!(email_verified_at: Time.current, role: :owner)
    @project=Project.create!(name: "Translation test")
    @membership=@project.project_memberships.create!(user: @user, role: "owner")
    @en=@project.languages.create!(name: "English", identifier: "en", enabled: true)
    @nl=@project.languages.create!(name: "Dutch", identifier: "nl", enabled: true)
    @sheet=@project.sheets.create!(name: "UI",default_language: @en)
    @tree=@sheet.translation_tree
    sign_in @user
  end
  test "create translate conflict export and soft delete" do
    post project_sheet_recordings_path(@project,@sheet), params: {name: "hello", translations: {@en.id=>"Hello"}}
    assert_response :see_other
    key=@tree.recordings.keys.sole
    get translations_project_sheet_path(@project,@sheet)
    assert_response :success
    assert_select 'se-input[type=textarea][autosize][fixed]'
    patch translation_project_sheet_recording_path(@project,@sheet,key), params: {language_id: @nl.id, text: "Hallo", version: "new"}, as: :json
    assert_response :success
    stored=response.parsed_body
    patch translation_project_sheet_recording_path(@project,@sheet,key), params: {language_id: @nl.id, text: "Stale", version: "new"}, as: :json
    assert_response :conflict
    patch translation_project_sheet_recording_path(@project,@sheet,key), params: {language_id: @nl.id, text: "Hoi", version: stored['version'], translation_id: stored['translation_id']}, as: :json
    assert_response :success
    @export_data = TranslationExport.new(@sheet).generate("json")
    assert_equal "Hoi", JSON.parse(export_entry("nl.json"))["hello"]
    @export_data = TranslationExport.new(@sheet).generate("yaml")
    assert_equal "Hello", YAML.safe_load(export_entry("en.yaml"))["hello"]
    @export_data = TranslationExport.new(@sheet).generate("csv")
    assert_includes @export_data, 'hello'
    delete project_sheet_recording_path(@project,@sheet,key), params: {version: key.reload.lock_version}
    assert_response :see_other
    assert @tree.recordings.active.empty?
    assert TextTranslation.exists?(text: "Hallo")
    post project_sheet_recordings_path(@project,@sheet), params: {name: "hello"}
    assert_response :see_other
    assert_equal 1,@tree.recordings.active.keys.count
  end
  test "translator language permissions and no key management" do
    users(:two).update!(role: :owner, email_verified_at: Time.current)
    @user.update!(role: :guest)
    @project.project_memberships.create!(user: users(:two),role: "owner")
    @membership.update!(role: "translator")
    key=Recording.create_key!(tree: @tree,parent: nil,name: "test")
    patch translation_project_sheet_recording_path(@project,@sheet,key),params: {language_id: @nl.id,text: "Hallo",version: "new"},as: :json
    assert_response :forbidden
    @membership.membership_languages.create!(language: @nl)
    patch translation_project_sheet_recording_path(@project,@sheet,key),params: {language_id: @nl.id,text: "Hallo",version: "new"},as: :json
    assert_response :success
    post project_sheet_recordings_path(@project,@sheet),params: {name: "forbidden"}
    assert_response :forbidden
    get translations_project_sheet_path(@project,@sheet)
    assert_response :success
    assert_select 'se-list-header se-select' do |selects|
      assert JSON.parse(selects.first['options']).any? { |option| option['icon'] == 'lock' }
    end
    assert_select 'se-list-header > div > se-icon', count: 0
  end
  test "nested keys plurals and missing default are exportable" do
    key=Recording.create_key!(tree: @tree,parent: nil,name: "items",values: {@en=>"Items",@nl=>"Artikelen"})
    patch pluralization_project_sheet_recording_path(@project,@sheet,key),params: {enabled: "1",version: key.lock_version}
    assert_response :see_other
    assert key.reload.recordable.pluralized
    other=key.children.active.keys.includes(:recordable).find { |r| r.recordable.name == "other" }
    assert_equal "other",other.recordable.name
    form=key.children.active.keys.includes(:recordable).find { |r| r.recordable.name == "few" }
    form.save_translation!(@nl,"Een paar")
    get translations_project_sheet_path(@project,@sheet,view: "tree")
    assert_response :success
    assert_includes response.body,"Een paar"
    get edit_project_sheet_recording_path(@project,@sheet,key)
    assert_response :success
    @export_data = TranslationExport.new(@sheet).generate("json")
    assert_equal "Een paar",JSON.parse(export_entry('nl.json')).dig('items','few')
  end
  test "sheet pages contain nine cards" do
    9.times { |n| @project.sheets.create!(name: "Sheet #{n}") }
    get project_sheets_path(@project)
    assert_select 'se-project-card',count: 9
    assert_select 'se-pagination[pages="2"]'
    get project_sheets_path(@project,page: 2)
    assert_select 'se-project-card',count: 1
  end
  test "export escapes reserved parent keys and respects missing value settings" do
    @sheet.update!(delimiter: "/", allow_parent_translations: true)
    parent=Recording.create_key!(tree:@tree,parent:nil,name:"item",values:{@en=>"Parent"})
    Recording.create_key!(tree:@tree,parent:parent,name:"0",values:{@en=>"Literal zero"})
    Recording.create_key!(tree:@tree,parent:parent,name:"a.b",values:{@en=>"Dotted"})
    @sheet.update!(missing_value_behavior:"fallback")
    @export_data = TranslationExport.new(@sheet).generate("json")
    result=JSON.parse(export_entry("nl.json"))
    assert_equal "Parent",result.dig("item","0")
    assert_equal "Literal zero",result.dig("item",'\\0')
    @export_data = TranslationExport.new(@sheet).generate("csv")
    assert_includes CSV.parse(@export_data).map(&:first),'item/a.b'
    @sheet.update!(missing_value_behavior:"empty")
    @export_data = TranslationExport.new(@sheet).generate("json")
    assert_equal "",JSON.parse(export_entry("nl.json")).dig("item","a.b")
  end
  test "key errors stay actionable and later pages detect concurrent changes" do
    key=Recording.create_key!(tree:@tree,parent:nil,name:"name")
    post project_sheet_recordings_path(@project,@sheet),params:{name:"NAME"},as: :json
    assert_response :unprocessable_entity
    assert_match /already exists/,response.parsed_body['error']
    get translations_project_sheet_path(@project,@sheet,view:"tree")
    assert_select 'se-list-row[level="0"]'
    assert_select 'se-menu[icon-only][data-key=?]',key.id
    get translations_project_sheet_path(@project,@sheet,after:50,revision:-1)
    assert_response :success
    assert_select 'turbo-frame[id="translation-page-50"]'
    assert_includes response.body,'Refresh results'
  end

  test "native table controls and plural rows in both views" do
    parent = Recording.create_key!(tree: @tree, parent: nil, name: "items", values: {@en => "Items"})
    patch pluralization_project_sheet_recording_path(@project, @sheet, parent), params: {enabled: "1", version: parent.lock_version}
    assert_response :see_other
    form = parent.children.active.keys.includes(:recordable).find { |r| r.recordable.name == "other" }
    %w[keys tree].each do |view|
      get translations_project_sheet_path(@project, @sheet, view: view)
      assert_response :success
      assert_select 'se-collection[dividers="1,2"][mobile-columns="repeat(2, minmax(0, 1fr))"] > se-list-header[sticky]'
      assert_select 'se-list-header > span[layout-mode=desktop-only]'
      assert_select '.translation-key[layout-mode=desktop-only]'
      assert_select 'se-list-header se-select[size="small"][data-language-side]', count: 2
      assert_select '.translation-toolbar se-select[data-language-side]', count: 0
      assert_select '.app-heading .app-row-actions se-button[text="Add key"]'
      assert_select 'se-list-row se-input[size="small"][autosize]'
      assert_select 'se-list-row se-menu[variant="mini"]' 
      assert_select 'se-list-row[data-key-row=?][collapsible][level="0"]', parent.id
      assert_select 'se-list-row[data-key-row=?][level="1"][guides][variant="secondary"]', form.id
      assert_select 'se-list-row[data-key-row=?][variant]', parent.id, count: 0
      assert_select 'se-input[type=search]:not([size])'
      assert_select '[data-translation-cell-target=editor]:not([hidden]) se-input[placeholder=""]'
      assert_select '.translation-save-status se-spinner[size=small]'
      assert_select 'se-popover[icon="funnel"] se-select[name="view"]'
      assert_select 'se-popover se-select[name="sort"]'
      assert_select 'se-menu[data-key=?]', parent.id do |menus|
        options = JSON.parse(menus.first['options'])
        assert options.any? { |option| option['heading'] == 'Pluralization' && option['separator'] }
        assert options.any? { |option| option['label'] == 'Show few' && option['id'] == 'plural' }
        assert_not options.any? { |option| option['label'] == 'Add other' }
      end
      assert_select 'se-nav-tabs > [data-actions] se-button[text="Export"]'
    end
    get translations_project_sheet_path(@project, @sheet)
    assert_select 'se-empty-illustration se-button', count: 0
    get project_sheets_path(@project)
    assert_select 'se-nav-tabs > [data-actions] se-button[text="Export"]'
  end

  test "search uses selected languages and retains tree ancestors and plural groups" do
    parent = Recording.create_key!(tree: @tree, parent: nil, name: "account")
    child = Recording.create_key!(tree: @tree, parent: parent, name: "name", values: {@en => "100% ready", @nl => "Gereed"})
    Recording.create_key!(tree: @tree, parent: nil, name: "unrelated", values: {@en => "1000 ready"})
    assert_equal [child.id], @tree.key_rows(query: "%", languages: [@en.id]).map { |row| row['id'] }
    assert_empty @tree.key_rows(query: "Gereed", languages: [@en.id])
    get translations_project_sheet_path(@project, @sheet, q: "Gereed", view: "tree")
    assert_select 'se-list-row', count: 2
    assert_select 'se-list-row[data-key-row=?]', parent.id
    assert_select 'se-list-row[data-key-row=?][level="1"]', child.id
    plural = Recording.create_key!(tree: @tree, parent: nil, name: "items", values: {@nl => "Artikelen"})
    patch pluralization_project_sheet_recording_path(@project, @sheet, plural), params: {enabled: "1", version: plural.lock_version}
    assert_response :see_other
    get translations_project_sheet_path(@project, @sheet, q: "Artikelen", view: "keys")
    assert_select 'se-list-row:not([hidden])', count: 3
    assert_select 'se-list-row[data-key-row=?]', plural.id
    assert_select 'se-list-row[level="1"]'
    get translations_project_sheet_path(@project, @sheet, q: "no such translation")
    assert_select 'se-empty-illustration[title="No matching translations"]'
  end

  test "later pages append to the same collection and preserve search" do
    52.times { |n| Recording.create_key!(tree: @tree, parent: nil, name: "key_%03d" % n) }
    get translations_project_sheet_path(@project, @sheet, q: "key_")
    assert_select 'se-list-row', count: 20
    assert_select 'turbo-frame[id="translation-page-20"][loading=lazy]' do |frames|
      assert_includes frames.first['src'], 'q=key_'
    end
    get translations_project_sheet_path(@project, @sheet, q: "key_", after: 50, revision: @tree.reload.revision)
    assert_select 'turbo-stream[action="append"][target="translation-rows"] template se-list-row', count: 2
    assert_select 'turbo-stream[action="replace"][target="translation-pagination"]'
    assert_select 'se-collection', count: 0
  end
  test "mobile uses sortable keys while retaining desktop tree preference" do
    parent = Recording.create_key!(tree: @tree, parent: nil, name: "z_parent")
    Recording.create_key!(tree: @tree, parent: parent, name: "child")
    get translations_project_sheet_path(@project, @sheet, view: "tree", mobile: "1", sort: "recent")
    assert_response :success
    assert_select 'se-list-header > span', text: 'Key'
    assert_select 'se-list-row[level="1"]', count: 0
    assert_select 'se-select[name="view"][value="tree"]'
    assert_select 'se-select[name="sort"][value="recent"]'
    assert_select '[data-mobile-search] [data-search-slot]'
  end

end
