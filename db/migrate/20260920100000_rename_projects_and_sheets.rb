class RenameProjectsAndSheets < ActiveRecord::Migration[8.1]
  def change
    rename_table :projects, :sheets
    rename_table :workspaces, :projects
    rename_column :sheets, :workspace_id, :project_id
    rename_table :workspace_memberships, :project_memberships
    rename_column :project_memberships, :workspace_id, :project_id
    rename_table :workspace_invites, :project_invites
    rename_column :project_invites, :workspace_id, :project_id
  end
end
