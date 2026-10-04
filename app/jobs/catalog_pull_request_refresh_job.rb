class CatalogPullRequestRefreshJob < ApplicationJob
  def perform(project_id, token)
    cache = CatalogPullRequestCache.find_by(project_id: project_id, refresh_token: token)
    return unless cache && cache.project.linked? && cache.connection == cache.connection_key
    project = cache.project
    api = CatalogGithub.new(project)
    previous = cache.current_pulls.index_by { |pull| pull['number'] }
    pulls = []
    Timeout.timeout(5.minutes) do
      page = 1
      loop do
        batch, more = api.incoming(page, include_outgoing: true)
        batch.each do |pull|
          identity = [pull.dig('base', 'sha'), pull.dig('head', 'sha')]
          old = previous[pull['number']]
          result = pull.slice('number', 'title', 'user').merge('identity' => identity)
          if old && old['identity'] == identity && old['error'].blank?
            result['changes'] = old['changes']
          else
            begin
              comparison = api.request(:get, "#{api.repo_path}/compare/#{api.escape(identity[0])}...#{api.escape(identity[1])}")
              _, before = api.snapshot(comparison.fetch('merge_base_commit').fetch('sha'))
              _, after = api.snapshot(identity[1])
              result['changes'] = CatalogPending.file_diff(before, after, project)
            rescue ArgumentError => error
              result.merge!('changes' => [], 'error' => error.message, 'invalid' => true)
            rescue CatalogGithub::Error => error
              result.merge!('changes' => [], 'error' => error.message)
            end
          end
          pulls << result
        end
        break unless more
        page += 1
      end
    end
    # A reconnect or newer job must never receive results from the old repository.
    return unless project.reload.linked? && cache.connection == cache.connection_key
    CatalogPullRequestCache.where(id: cache.id, refresh_token: token).update_all(pulls: pulls, fetched_at: Time.current, error: nil, refresh_token: nil, updated_at: Time.current)
  rescue CatalogGithub::Error, ArgumentError, KeyError, Timeout::Error => error
    CatalogPullRequestCache.where(project_id: project_id, refresh_token: token).update_all(error: error.is_a?(Timeout::Error) ? 'Pull request refresh timed out. The previous snapshot is still available.' : error.message, refresh_token: nil)
  rescue StandardError
    CatalogPullRequestCache.where(project_id: project_id, refresh_token: token).update_all(error: 'Pull request refresh failed. The previous snapshot is still available.', refresh_token: nil)
    raise
  end
end
