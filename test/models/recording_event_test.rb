require "test_helper"
require "minitest/mock"

class RecordingEventTest < ActiveSupport::TestCase
  setup do
    @actor = users(:one)
    @actor.update!(email_verified_at: Time.current)
    @project = Project.create!(name: "History")
    @language = @project.languages.create!(name: "English", identifier: "en", enabled: true)
    @sheet = @project.sheets.create!(name: "Words", default_language: @language)
  end

  test "restoring an event restores the entire sheet to that point" do
    french = @project.languages.create!(name: "French", identifier: "fr", enabled: true)
    key = travel_to(3.hours.ago) { Recording.create_key!(tree: @sheet.translation_tree, parent: nil, name: "greeting", actor: @actor) }
    assert_equal [ "created" ], key.recording_events.pluck(:action)

    value = travel_to(3.hours.ago) { key.save_translation!(@language, "Hello", actor: @actor) }
    target = value.recording_events.sole
    travel_to(2.hours.ago) { key.save_translation!(@language, "Hi", actor: @actor) }
    french_value = travel_to(1.hour.ago) { key.save_translation!(french, "Bonjour", actor: @actor) }
    later_key = travel_to(30.minutes.ago) { Recording.create_key!(tree: @sheet.translation_tree, parent: nil, name: "later", actor: @actor) }

    assert_equal 3, target.restore_sheet!(actor: @actor)
    assert_equal "Hello", value.reload.recordable.text
    assert_nil value.deleted_at
    assert french_value.reload.deleted_at?
    assert later_key.reload.deleted_at?
    reverted = RecordingEvent.where(change_type: "revert").order(:id)
    assert_equal %w[updated deleted deleted], reverted.pluck(:action)
    assert_equal 1, reverted.distinct.count(:created_at)
    assert_equal 1, reverted.distinct.count(:change_id)
  end

  test "same-time subtree events remain distinct restore points" do
    key = travel_to(2.hours.ago) { Recording.create_key!(tree: @sheet.translation_tree, parent: nil, name: "legacy", values: { @language => "Old" }, actor: @actor) }
    value = key.children.texts.sole
    travel_to(1.hour.ago) { key.discard_subtree!(expected: key.lock_version, actor: @actor) }
    deletion_events = RecordingEvent.where(recording: [ key, value ], action: "deleted").order(id: :desc)

    assert_equal %w[TranslationKey TextTranslation], deletion_events.pluck(:recordable_type)
    assert_equal 1, deletion_events.last.restore_sheet!(actor: @actor)
    assert_nil key.reload.deleted_at
    assert value.reload.deleted_at?
  end

  test "the selected history event is included in the restored state" do
    key = Recording.create_key!(tree: @sheet.translation_tree, parent: nil, name: "greeting", actor: @actor)
    value = key.save_translation!(@language, "Hello", actor: @actor)
    selected = value.recording_events.sole
    key.save_translation!(@language, "Later", actor: @actor)

    selected.restore_sheet!(actor: @actor)

    assert_equal "Hello", value.reload.recordable.text
  end

  test "restoring a subtree activates parents before children" do
    parent = Recording.create_key!(tree: @sheet.translation_tree, parent: nil, name: "parent", actor: @actor)
    child = Recording.create_key!(tree: @sheet.translation_tree, parent: parent, name: "child", actor: @actor)
    value = child.save_translation!(@language, "Hello", actor: @actor)
    target = value.recording_events.sole
    parent.discard_subtree!(expected: parent.lock_version, actor: @actor)
    snapshot = RecordingSnapshot.new(target)
    states = snapshot.states.index_by(&:id)
    snapshot.states.replace(Recording.descendants_first(snapshot.states.map(&:recording)).map { |recording| states.fetch(recording.id) })

    RecordingSnapshot.stub(:new, snapshot) { assert_equal 3, target.restore_sheet!(actor: @actor) }
    assert [ parent, child, value ].all? { |recording| !recording.reload.deleted_at? }
  end

  test "recordings cannot be moved" do
    one = Recording.create_key!(tree: @sheet.translation_tree, parent: nil, name: "one")
    two = Recording.create_key!(tree: @sheet.translation_tree, parent: nil, name: "two")
    assert_raises(ActiveRecord::StatementInvalid) { two.update!(parent: one) }
  end

  test "deleting an actor keeps history" do
    key = Recording.create_key!(tree: @sheet.translation_tree, parent: nil, name: "greeting", actor: @actor)
    @actor.auth_identities.delete_all
    @actor.delete
    assert_nil key.recording_events.sole.reload.actor_id
  end
end
