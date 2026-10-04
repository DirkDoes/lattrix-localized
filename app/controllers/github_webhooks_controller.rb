class GithubWebhooksController < ActionController::Base
  skip_forgery_protection
  def create
    secret = GithubAppConfiguration.current.webhook_secret
    body = request.raw_post
    return head :unauthorized if secret.blank? || body.bytesize > 5.megabytes
    signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
    return head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(signature, request.headers["X-Hub-Signature-256"].to_s)
    payload = JSON.parse(body)
    return head :bad_request unless payload.is_a?(Hash)
    return head :accepted if request.headers['X-GitHub-Event'] == 'ping'
    return head :bad_request unless payload['repository'].is_a?(Hash) && payload['installation'].is_a?(Hash)
    return head :bad_request unless payload.dig('repository', 'full_name').is_a?(String) && payload.dig('installation', 'id').is_a?(Integer)
    Project.where(repository: payload.dig("repository", "full_name"), installation_id: payload.dig("installation", "id")).find_each do |project|
      case request.headers["X-GitHub-Event"]
      when "push"
        CatalogSyncJob.perform_later(project.id) if payload["ref"] == "refs/heads/#{project.git_branch}"
      when "pull_request"
        cache = CatalogPullRequestCache.for(project)
        if payload['action'] == 'closed'
          cache.with_lock { cache.update!(pulls: cache.pulls.reject { |pull| pull['number'] == payload['number'] }, refresh_token: nil) }
        end
        cache.refresh_later(force: true)
        if %w[opened synchronize reopened].include?(payload["action"]) && payload.dig("pull_request", "base", "ref") == project.git_branch
          CatalogCheckJob.perform_later(project.id, payload.fetch("number"))
        end
        CatalogSyncJob.perform_later(project.id) if payload.dig("pull_request", "merged")
      when "create"
        CatalogTagJob.perform_later(project.id, payload["ref"]) if payload["ref_type"] == "tag"
      end
    end
    head :accepted
  rescue JSON::ParserError
    head :bad_request
  end
end
