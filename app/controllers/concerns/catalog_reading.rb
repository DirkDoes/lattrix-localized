module CatalogReading
  extend ActiveSupport::Concern

  included do
    around_action :time_catalog_read, only: [:translations, :editor]
  end

  private

  def catalog_read_etag
    membership = current_user && @project.project_memberships.find_by(user: current_user)
    reviews = CatalogReview.joins(:catalog_node).where(catalog_nodes: {project_id: @project.id})
      .pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(catalog_reviews.updated_at)"))
    token = [@project.cache_key_with_version, @project.revision, @project.writable?, current_user&.cache_key_with_version,
      membership&.cache_key_with_version, membership&.membership_languages&.order(:language_id)&.pluck(:language_id),
      @languages.map(&:cache_key_with_version), reviews.first, reviews.last&.iso8601(6)]
    %(W/"#{Digest::SHA256.hexdigest(token.to_json)}")
  end

  def time_catalog_read
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    thread = Thread.current
    database = 0.0
    subscriber = ActiveSupport::Notifications.monotonic_subscribe("sql.active_record") do |_name, start, finish, _id, payload|
      database += (finish - start) * 1000 if Thread.current == thread && !payload[:cached] && payload[:name] != "SCHEMA"
    end
    yield
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    total = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    timings = {catalog: total, db: database, projection: @catalog_projection_ms, view: @catalog_render_ms}
    response.set_header("Server-Timing", timings.compact.map { |name, duration| "#{name};dur=#{duration.round(2)}" }.join(", "))
  end

  def render_catalog_read
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    @catalog_render_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
  end
end
