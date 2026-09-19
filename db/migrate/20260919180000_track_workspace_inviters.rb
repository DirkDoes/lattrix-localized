class TrackWorkspaceInviters < ActiveRecord::Migration[8.1]
  def change
    add_reference :workspace_invites, :invited_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
  end
end
