class AddCatalogFileGroups < ActiveRecord::Migration[8.1]
  def change
    add_column :catalog_keys, :file_group, :string, null: false, default: ""
  end
end
