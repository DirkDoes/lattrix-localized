class AddSheetWildcardFormat < ActiveRecord::Migration[8.0]
  def change
    add_column :sheets, :wildcard_format, :string, null: false, default: ""
  end
end
