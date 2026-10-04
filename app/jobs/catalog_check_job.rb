class CatalogCheckJob < ApplicationJob
  def perform(project_id, number)
    project = Project.find_by(id: project_id)
    return unless project&.linked?
    api = CatalogGithub.new(project)
    pr = api.request(:get, "#{api.repo_path}/pulls/#{Integer(number)}")
    return unless pr.dig("base", "ref") == project.git_branch
    unless project.pr_validation_enabled?
      api.request(:post, "#{api.repo_path}/check-runs", {name: "Lattrix translations", head_sha: pr.fetch("head").fetch("sha"), status: "completed", conclusion: "neutral", output: {title: "Validation disabled", summary: "PR validation is disabled in the Lattrix project settings."}})
      return
    end
    check = api.request(:post, "#{api.repo_path}/check-runs", {name: "Lattrix translations", head_sha: pr.fetch("head").fetch("sha"), status: "in_progress"})
    failure = nil
    begin
      # Pin the inspected SHA so a subsequent push cannot attach a result to the wrong commit.
      commit, files = api.snapshot(pr.fetch("head").fetch("sha"))
      Project.transaction(requires_new: true) do
        CatalogReconcile.new(project, files, sha: commit.fetch("sha"), pr_check: true).apply!
        raise ActiveRecord::Rollback
      end
    rescue ArgumentError, ActiveRecord::RecordInvalid, CatalogGithub::Error => error
      failure = error.message
    end
    api.request(:patch, "#{api.repo_path}/check-runs/#{check.fetch('id')}", {status: "completed", conclusion: failure ? "failure" : "success", output: {title: failure ? "Invalid translations" : "Translations are valid", summary: failure || "Enabled translation checks passed. Disabled checks were not evaluated."}})
  end
end
