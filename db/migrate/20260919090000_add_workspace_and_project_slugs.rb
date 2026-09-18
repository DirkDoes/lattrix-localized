class AddWorkspaceAndProjectSlugs < ActiveRecord::Migration[8.1]
  def up
    add_column :workspaces, :slug, :string
    add_column :projects, :slug, :string
    [:workspaces, :projects].each do |table|
      model = Class.new(ActiveRecord::Base) { self.table_name = table.to_s }
      model.order(:created_at, :id).each do |record|
        base = record.name.parameterize.first(90).sub(/-+\z/, "").presence || table.to_s.singularize
        base = "#{base}-1" if %w[new edit].include?(base)
        scope = table == :projects ? model.where(workspace_id: record.workspace_id) : model.all
        slug = base
        suffix = 2
        while scope.exists?(slug: slug)
          slug = "#{base}-#{suffix}"
          suffix += 1
        end
        record.update_columns(slug: slug)
      end
      change_column_null table, :slug, false
      add_check_constraint table, "slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(slug) <= 100 AND slug NOT IN ('new', 'edit')", name: "#{table}_slug_format"
    end
    add_index :workspaces, :slug, unique: true
    add_index :projects, [:workspace_id, :slug], unique: true
  end

  def down
    remove_column :projects, :slug
    remove_column :workspaces, :slug
  end
end
