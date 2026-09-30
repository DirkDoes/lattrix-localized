class CatalogCheckJob < ApplicationJob
  def perform(project_id, number)
    project = Project.find_by(id: project_id)
    return unless project&.linked?
    api = CatalogGithub.new(project)
    pr = api.request(:get, "#{api.repo_path}/pulls/#{Integer(number)}")
    return unless pr.dig("base", "ref") == project.git_branch
    commit, files = api.snapshot("refs/pull/#{Integer(number)}/head")
    failure = nil
    # Validate using the very same reconciliation, but never persist a PR as authoritative.
    Project.transaction(requires_new: true) do
      begin
        CatalogReconcile.new(project, files, sha: commit.fetch("sha")).apply!
      rescue ArgumentError, ActiveRecord::RecordInvalid => error
        failure = error.message
      ensure
        raise ActiveRecord::Rollback
      end
    end
    api.request(:post, "#{api.repo_path}/check-runs", {name: "Lattrix translations", head_sha: commit.fetch("sha"), status: "completed", conclusion: failure ? "failure" : "success", output: {title: failure ? "Invalid translations" : "Translations are valid", summary: failure || "Structure, plural categories and placeholders are valid."}})
  end
end
