require "test_helper"
class TranslationStructureTest < ActiveSupport::TestCase
  setup do
    @project=Project.create!(name: "Structure")
    @en=@project.languages.create!(name: "English",identifier: "en",enabled: true)
    @sheet=@project.sheets.create!(name: "Test",default_language: @en)
    @tree=@sheet.translation_tree
  end
  def key(name,parent=nil)
    Recording.create_key!(tree: @tree,parent: parent,name: name)
  end
  def rejected
    assert_raises(ActiveRecord::StatementInvalid) { ApplicationRecord.transaction(requires_new: true) { yield } }
  end
  test "database rejects immutable writes duplicate siblings and duplicate locale values" do
    root=key("Name")
    rejected { root.recordable.update_columns(name: "changed") }
    rejected { key("name") }
    @sheet.update!(case_sensitive_keys: true)
    key("name")
    rejected { @sheet.update_columns(case_sensitive_keys: false) }
    value=root.save_translation!(@en,"Name")
    rejected { value.recordable.delete }
    rejected { root.children.create!(translation_tree: @tree, recordable: TextTranslation.create!(language: @en,text: "Another")) }
    rejected { TextTranslation.insert_all!([{language_id: @en.id,text: "",created_at: Time.current,updated_at: Time.current}]) }
  end
  test "database rejects cycles cross tree and cross project language references" do
    root=key("root");child=key("child",root)
    rejected { root.update_columns(parent_id: child.id) }
    other=@project.sheets.create!(name:"Other").translation_tree
    rejected { child.update_columns(translation_tree_id: other.id) }
    rejected { @tree.update_columns(sheet_id: other.sheet_id) }
    p=Project.create!(name:"Other project")
    l=p.languages.create!(name:"Other",identifier:"x",enabled:true)
    rejected { root.children.create!(translation_tree:@tree,recordable:TextTranslation.create!(language:l,text:"Bad")) }
    rejected { @sheet.update_columns(default_language_id:l.id) }
    rejected { @en.update_columns(project_id:p.id) }
  end
  test "soft deletion preserves payloads and permits reuse while moves preserve identities" do
    root=key("root");child=key("child",root)
    value=child.save_translation!(@en,"Value")
    root.change_key!(name:"renamed",parent_id:nil,expected:root.lock_version)
    assert_equal child.id,@tree.recordings.keys.find_by(parent_id:root.id).id
    assert_equal "Value",value.reload.recordable.text
    root.discard_subtree!(expected:root.reload.lock_version)
    assert_equal 0,@tree.recordings.active.count
    assert TextTranslation.exists?(value.recordable_id)
    assert key("renamed")
  end
  test "parent restriction is checked on create translation move and setting change" do
    @sheet.update!(allow_parent_translations: true)
    root=key("root");root.save_translation!(@en,"Root")
    child=key("child",root)
    assert_not @sheet.update(allow_parent_translations:false)
    child.discard_subtree!(expected:child.lock_version)
    @sheet.reload.update!(allow_parent_translations:false)
    assert_raises(ArgumentError) { key("other",root) }
  end
  test "language union deactivation and identifier stability" do
    extra=@project.languages.create!(name:"Pirate",identifier:"pirate",enabled:false)
    assert_not @sheet.active_languages.exists?(extra.id)
    @sheet.sheet_languages.create!(language:extra)
    assert @sheet.active_languages.exists?(extra.id)
    root=key("hello");root.save_translation!(extra,"Ahoy")
    extra.update!(name:"Pirate speak",identifier:"pirate-speak")
    @sheet.sheet_languages.find_by(language:extra).update!(enabled:false)
    assert_equal 1,root.children.active.count
    @sheet.sheet_languages.find_by(language:extra).update!(enabled:true)
    assert_equal "Ahoy",root.children.sole.recordable.text
    assert_not @en.update(enabled:false)
  end
  test "last owner is checked even for raw SQL" do
    user=users(:one); user.update!(role: :owner,email_verified_at:Time.current)
    users(:two).update!(role: :guest)
    rejected do
      user.update_columns(role:0)
      ApplicationRecord.connection.execute("SET CONSTRAINTS last_global_owner IMMEDIATE")
    end
    member=@project.project_memberships.create!(user:user,role:"owner")
    rejected do
      member.update_columns(role:"viewer")
      ApplicationRecord.connection.execute("SET CONSTRAINTS last_project_owner IMMEDIATE")
    end
  end
  test "project deletion retains immutable payload language identities" do
    value=key("test").save_translation!(@en,"Value")
    @project.destroy!
    ApplicationRecord.connection.execute("SET CONSTRAINTS retained_language IMMEDIATE")
    assert TextTranslation.exists?(value.recordable_id)
    assert_nil @en.reload.project_id
  end

end
