class TrackPendingRepositoryLanguages < ActiveRecord::Migration[8.1]
  def change
    add_column :languages, :pending_repository, :boolean, null: false, default: false
  end
end
