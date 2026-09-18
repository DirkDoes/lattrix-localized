class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects, id: :uuid do |t|
      t.references :workspace, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false
      t.string :visibility, null: false, default: "private"
      t.timestamps
    end
    add_check_constraint :projects, "visibility IN ('public', 'private')", name: "projects_visibility"
  end
end
