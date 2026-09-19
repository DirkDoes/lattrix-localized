class AddRoleToWorkspaceInvites < ActiveRecord::Migration[8.1]
  def change
    add_column :workspace_invites, :role, :string, null: false, default: "viewer"
    add_check_constraint :workspace_invites, "role IN ('viewer', 'translator')", name: "workspace_invite_role"
  end
end
