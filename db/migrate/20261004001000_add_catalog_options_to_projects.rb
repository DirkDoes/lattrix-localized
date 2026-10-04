class AddCatalogOptionsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :max_locale_files, :integer, null: false, default: 100
    add_column :projects, :max_locale_file_mb, :integer, null: false, default: 3
    add_column :projects, :max_locale_total_mb, :integer, null: false, default: 15
    add_column :projects, :pluralization_mode, :string, null: false, default: "cldr"
    change_column_default :projects, :pluralization_mode, from: "cldr", to: "simple"
    add_column :projects, :pr_validation_enabled, :boolean, null: false, default: true
    add_column :projects, :pr_validation_checks, :jsonb, null: false, default: {}
    %i[max_locale_files max_locale_file_mb max_locale_total_mb].each do |column|
      add_check_constraint :projects, "#{column} > 0", name: "projects_#{column}_positive"
    end
    add_check_constraint :projects, "pluralization_mode IN ('off', 'simple', 'cldr')", name: "projects_pluralization_mode"
  end
end
