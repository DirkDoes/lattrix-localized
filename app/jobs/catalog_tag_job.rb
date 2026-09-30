class CatalogTagJob < ApplicationJob
  def perform(project_id, name)
    project = Project.find_by(id: project_id)
    return unless project&.linked?
    return if project.catalog_tags.exists?(name: name)
    commit, = CatalogGithub.new(project).snapshot(name)
    revision = project.catalog_change_sets.find_by(commit_sha: commit.fetch("sha"))
    project.catalog_tags.find_or_create_by!(name: name) do |tag|
      tag.commit_sha = commit.fetch("sha")
      tag.event_position = revision&.catalog_events&.maximum(:id)
    end
  end
end
