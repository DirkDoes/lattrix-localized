class AllowExternalCatalogTags < ActiveRecord::Migration[8.1]
  def change
    change_column_null :catalog_tags, :event_position, true
  end
end
