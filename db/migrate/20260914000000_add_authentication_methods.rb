class AddAuthenticationMethods < ActiveRecord::Migration[8.1]
  def up
    # Preserve accounts; old sessions naturally expire when their numeric IDs stop resolving.
    execute "ALTER TABLE users ADD COLUMN uuid uuid NOT NULL DEFAULT gen_random_uuid()"
    execute "ALTER TABLE users DROP CONSTRAINT users_pkey"
    remove_column :users, :id
    rename_column :users, :uuid, :id
    execute "ALTER TABLE users ADD PRIMARY KEY (id)"
    execute "UPDATE users SET email = lower(trim(email))"
    add_index :users, "lower(email)", unique: true, name: "index_users_on_normalized_email"
    add_column :users, :email_verified_at, :datetime
    add_column :users, :banned_at, :datetime

    create_table :auth_identities, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :provider_uid, null: false
      t.timestamps
    end
    add_index :auth_identities, [:provider, :provider_uid], unique: true
    add_index :auth_identities, [:user_id, :provider], unique: true
    execute <<~SQL
      INSERT INTO auth_identities (id, user_id, provider, provider_uid, created_at, updated_at)
      SELECT gen_random_uuid(), id, 'google', uid, NOW(), NOW() FROM users
      WHERE provider = 'google_oauth2' AND uid IS NOT NULL AND uid <> ''
    SQL
    remove_column :users, :provider
    remove_column :users, :uid

    create_table :email_challenges, id: :uuid do |t|
      t.string :email, null: false
      t.string :purpose, null: false
      t.string :digest, null: false
      t.string :password_digest
      t.string :name
      t.datetime :expires_at, null: false
      t.integer :attempts, null: false, default: 0
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :email_challenges, [:email, :purpose], unique: true
    add_index :email_challenges, :expires_at
    create_table :auth_rate_limits, id: false do |t|
      t.string :key, null: false, primary_key: true
      t.integer :count, null: false, default: 0
      t.datetime :expires_at, null: false
    end
    add_index :auth_rate_limits, :expires_at
    create_table :invitations, id: :uuid do |t|
      t.string :email, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :invitations, :email, unique: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "User IDs have been converted to UUIDs"
  end
end
