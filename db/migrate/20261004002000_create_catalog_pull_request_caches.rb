class CreateCatalogPullRequestCaches < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_pull_request_caches do |t|
      t.references :project, null: false, index: {unique: true}, foreign_key: true
      t.string :connection
      t.jsonb :pulls, null: false, default: []
      t.string :refresh_token
      t.datetime :requested_at
      t.datetime :fetched_at
      t.text :error
      t.timestamps
    end
  end
end
