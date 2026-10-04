# Display-only GitHub snapshots, independent of the editable catalog and its history.
class CatalogPullRequestCache < ApplicationRecord
  belongs_to :project

  def self.for(project)
    create_or_find_by!(project: project)
  end

  def connection_key
    Digest::SHA256.hexdigest([project.repository, project.installation_id, project.git_branch, project.locale_directory,
      project.max_locale_files, project.max_locale_file_mb, project.max_locale_total_mb].to_json)
  end

  def current_pulls = connection == connection_key ? pulls : []
  def refreshing? = refresh_token.present? && requested_at && requested_at > 10.minutes.ago

  def refresh_later(force: false)
    return unless project.linked?
    token = nil
    with_lock do
      next if refreshing? && !force && connection == connection_key
      next if !force && connection == connection_key && ((fetched_at && fetched_at > 10.minutes.ago) || (error.present? && requested_at && requested_at > 1.minute.ago))
      token = SecureRandom.uuid
      attributes = {connection: connection_key, refresh_token: token, requested_at: Time.current, error: nil}
      attributes.merge!(pulls: [], fetched_at: nil) if connection != connection_key
      update!(attributes)
    end
    CatalogPullRequestRefreshJob.perform_later(project_id, token) if token
  rescue StandardError => exception
    self.class.where(id: id, refresh_token: token).update_all(refresh_token: nil, error: 'Could not queue pull request refresh. Please retry shortly.') if token
    Rails.logger.warn("Could not queue PR cache refresh: #{exception.class}")
    false
  end
end
