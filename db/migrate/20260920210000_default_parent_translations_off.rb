class DefaultParentTranslationsOff < ActiveRecord::Migration[8.1]
  def change
    change_column_default :sheets, :allow_parent_translations, from: true, to: false
  end
end
