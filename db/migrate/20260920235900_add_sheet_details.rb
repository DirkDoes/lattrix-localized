class AddSheetDetails < ActiveRecord::Migration[8.1]
  def change
    add_column :sheets, :description, :text
    add_column :sheets, :image_data, :binary
  end
end
