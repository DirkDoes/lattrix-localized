class AddDisplayNameToAuthIdentities < ActiveRecord::Migration[8.1]
  def change
    add_column :auth_identities, :display_name, :string
  end
end
