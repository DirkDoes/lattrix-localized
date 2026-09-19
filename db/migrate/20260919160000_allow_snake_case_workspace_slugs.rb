class AllowSnakeCaseWorkspaceSlugs < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :workspaces, name: "workspaces_slug_format", expression: "slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(slug) <= 100 AND slug NOT IN ('new', 'edit')"
    add_check_constraint :workspaces, "slug ~ '^[a-z0-9]+([-_][a-z0-9]+)*$' AND length(slug) <= 100 AND slug NOT IN ('new', 'edit')", name: "workspaces_slug_format"
  end
end
