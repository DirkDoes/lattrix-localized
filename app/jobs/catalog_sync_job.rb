class CatalogSyncJob < ApplicationJob
  queue_as :default
  def perform(project_id, publish: false, initial: false)
    project = Project.find_by(id: project_id)
    return unless project&.linked?
    # ponytail: lock per project through network I/O; use a leased sync lock if contention grows.
    project.with_lock do
      api = CatalogGithub.new(project)
      project.update!(git_branch: api.repository.fetch("default_branch")) if project.git_branch.blank?
      commit, files = api.snapshot
      if initial && project.git_sha.nil?
        project.catalog_nodes.where(deleted: false).each do |node|
          draft = project.catalog_drafts.find_or_initialize_by(catalog_node: node)
          next if draft.persisted?
          draft.update!(base_type: node.payload_type, base_id: node.payload_id, base_parent_id: node.parent_id, base_deleted: true, payload: node.payload, parent_id: node.parent_id, deleted: false)
        end
      end
      CatalogReconcile.new(project, files, sha: commit.fetch("sha"), author: commit.dig("author", "login") || commit.dig("commit", "author", "name")).apply!
      if publish
        state = CatalogState.new(project, pending: true).publication
        accepted = CatalogState.new(project)
        if state.items.any? { |id, item| accepted.items[id]&.signature != item.signature }
          parsed = CatalogYaml.new(files)
          api.publish!(commit, CatalogExport.new(project, state: state).files(existing: parsed.documents), files)
        end
      end
    end
  rescue CatalogGithub::Error, ArgumentError, ActiveRecord::RecordInvalid, KeyError => error
    project&.update!(sync_error: error.message)
  end
end
