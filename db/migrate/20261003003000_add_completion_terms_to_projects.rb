class AddCompletionTermsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :completion_terms, :jsonb, default: [], null: false
  end
end
