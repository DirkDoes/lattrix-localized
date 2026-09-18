class AddProfilePhotos < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :profile_photo, :binary
    add_column :users, :profile_photo_customized, :boolean, default: false, null: false
  end
end
