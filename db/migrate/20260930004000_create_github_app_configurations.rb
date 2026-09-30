class CreateGithubAppConfigurations < ActiveRecord::Migration[8.1]
  def change
    create_table :github_app_configurations do |t|
      t.string :app_id, null: false
      t.text :private_key, null: false
      t.text :webhook_secret, null: false
      t.timestamps
    end
    add_check_constraint :github_app_configurations, 'id = 1', name: 'one_github_app_configuration'
  end
end
