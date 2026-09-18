class CreateWorkspaces < ActiveRecord::Migration[8.1]
  def change
    create_table :workspaces, id: :uuid do |t|
      t.string :name, null: false
      t.string :visibility, null: false, default: "private"
      t.timestamps
    end
    add_check_constraint :workspaces, "visibility IN ('public', 'private')", name: "workspace_visibility"
    create_table :workspace_memberships, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :role, null: false, default: "viewer"
      t.timestamps
    end
    add_index :workspace_memberships, [ :workspace_id, :user_id ], unique: true
    add_check_constraint :workspace_memberships, "role IN ('viewer', 'translator', 'admin', 'owner')", name: "workspace_membership_role"
    create_table :workspace_invites, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.string :email, null: false
      t.timestamps
    end
    add_index :workspace_invites, [ :workspace_id, :email ], unique: true
  end
end
