class CatalogSyncJob < ApplicationJob
  queue_as :default
  around_enqueue do |job, enqueue|
    scope = Project.where(id: job.arguments.first)
    scope.update_all(sync_status: "queued", sync_job_id: job.job_id, sync_requested_at: Time.current, sync_finished_at: nil, sync_message: nil)
    begin
      enqueue.call
      raise "Synchronization could not be queued" unless job.successfully_enqueued?
    rescue StandardError
      scope.where(sync_job_id: job.job_id).update_all(sync_status: "failed", sync_message: "Could not queue synchronization. Please retry.", sync_finished_at: Time.current)
      raise
    end
  end

  def perform(project_id, publish: false, initial: false)
    project = Project.find_by(id: project_id)
    return unless project&.linked?
    # perform_now is also used for diagnostics/tests, without an enqueue callback.
    project.update!(sync_job_id: job_id, sync_requested_at: Time.current) if project.sync_job_id.nil?
    tracking = Project.where(id: project.id, sync_job_id: job_id)
    tracking.update_all(sync_status: "running")
    message = "Already up to date. No catalog changes were needed."
    Timeout.timeout(15.minutes) do
    # ponytail: lock per project through network I/O; use a leased sync lock if contention grows.
    project.with_lock do
      api = CatalogGithub.new(project)
      previous_event = project.catalog_events.maximum(:id).to_i
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
      changes = project.catalog_events.where("catalog_events.id > ?", previous_event).count
      message = "Synchronization complete. #{changes} changes applied." if changes.positive?
      if publish
        state = CatalogState.new(project, pending: true).publication
        accepted = CatalogState.new(project)
        if project.languages.active.where(pending_repository: true).exists? || state.items.any? { |id, item| accepted.items[id]&.signature != item.signature }
          parsed = CatalogYaml.new(files, project)
          published = api.publish!(commit, CatalogExport.new(project, state: state).files(existing: parsed.documents, originals: files), files)
          message = published ? "Synchronization complete. Pull request ##{project.pull_request_number} is ready." : "Synchronization complete. Exported files are unchanged; no pull request was generated."
        else
          message = "Synchronization complete. No publishable pending changes; no pull request was generated."
        end
      end
    end
    end
    tracking.update_all(sync_status: "succeeded", sync_message: message, sync_finished_at: Time.current)
  rescue CatalogGithub::Error, ArgumentError, ActiveRecord::RecordInvalid, KeyError, Timeout::Error => error
    project&.update!(sync_error: error.message)
    tracking&.update_all(sync_status: "failed", sync_message: error.is_a?(Timeout::Error) ? "Synchronization timed out. Please retry." : error.message, sync_finished_at: Time.current)
  rescue StandardError
    tracking&.update_all(sync_status: "failed", sync_message: "Synchronization failed unexpectedly. Please retry or contact an administrator.", sync_finished_at: Time.current)
    raise
  end
end
