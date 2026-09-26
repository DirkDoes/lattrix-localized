class ReplaceRevertedWithChangeType < ActiveRecord::Migration[8.1]
  def up
    add_column :recording_events, :change_type, :string, null: false, default: "manual"
    execute "UPDATE recording_events SET change_type='revert' WHERE reverted"
    add_check_constraint :recording_events, "change_type IN ('manual','revert','import')", name: "recording_event_change_type"
    remove_column :recording_events, :reverted
  end

  def down
    add_column :recording_events, :reverted, :boolean, null: false, default: false
    execute "UPDATE recording_events SET reverted=TRUE WHERE change_type='revert'"
    remove_check_constraint :recording_events, name: "recording_event_change_type"
    remove_column :recording_events, :change_type
  end
end
