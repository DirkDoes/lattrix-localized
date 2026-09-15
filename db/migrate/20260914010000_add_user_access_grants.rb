class AddUserAccessGrants < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :access_granted_at, :datetime
    # Preserve admission for accounts created under the previous invitation policy.
    execute "UPDATE users SET access_granted_at = CURRENT_TIMESTAMP"
  end

  def down
    remove_column :users, :access_granted_at
  end
end
