class RenameProjectSheetConstraints < ActiveRecord::Migration[8.1]
  RENAMES = {
    sheets: {projects_visibility: :sheets_visibility, projects_slug_format: :sheets_slug_format},
    projects: {workspace_visibility: :projects_visibility, workspaces_slug_format: :projects_slug_format},
    project_memberships: {workspace_membership_role: :project_membership_role},
    project_invites: {workspace_invite_role: :project_invite_role}
  }.freeze
  def up
    RENAMES.each { |table,names| names.each { |old_name,new_name| execute "ALTER TABLE #{table} RENAME CONSTRAINT #{old_name} TO #{new_name}" } }
  end
  def down
    RENAMES.each { |table,names| names.each { |old_name,new_name| execute "ALTER TABLE #{table} RENAME CONSTRAINT #{new_name} TO #{old_name}" } }
  end
end
