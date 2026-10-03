class TrackCatalogSyncStatus < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :sync_status, :string, null: false, default: "idle"
    add_column :projects, :sync_job_id, :string
    add_column :projects, :sync_requested_at, :datetime
    add_column :projects, :sync_finished_at, :datetime
    add_column :projects, :sync_message, :text
  end
end
