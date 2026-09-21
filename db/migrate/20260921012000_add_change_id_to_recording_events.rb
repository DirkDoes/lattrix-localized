class AddChangeIdToRecordingEvents < ActiveRecord::Migration[8.1]
  def up
    add_column :recording_events, :change_id, :bigint
    execute "UPDATE recording_events SET change_id=id"
    execute "CREATE SEQUENCE recording_event_change_ids"
    execute "SELECT setval('recording_event_change_ids', COALESCE(MAX(change_id), 0) + 1, false) FROM recording_events"
    execute "ALTER SEQUENCE recording_event_change_ids OWNED BY recording_events.change_id"
    execute "ALTER TABLE recording_events ALTER COLUMN change_id SET DEFAULT nextval('recording_event_change_ids')"
    change_column_null :recording_events, :change_id, false
    add_index :recording_events, :change_id
  end

  def down
    remove_column :recording_events, :change_id
  end
end
