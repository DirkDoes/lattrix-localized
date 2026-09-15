class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :encrypted_password, null: false, default: ""
      t.string :name
      t.string :provider
      t.datetime :remember_created_at
      t.datetime :reset_password_sent_at
      t.string :reset_password_token
      t.integer :role, null: false, default: 0
      t.string :theme_preference, null: false, default: "system"
      t.string :uid

      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, [:provider, :uid], unique: true
    add_index :users, :reset_password_token, unique: true
  end
end
