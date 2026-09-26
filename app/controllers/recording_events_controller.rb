class RecordingEventsController < ApplicationController
  PREVIEW_SIZE = 10
  BATCH_SIZE = 20

  layout "settings"
  after_action :verify_authorized
  before_action :set_sheet

  def index
    authorize @sheet, :history?
    scope = filtered_scope
    @pages = [ (scope.distinct.count(:change_id) + 29) / 30, 1 ].max
    @page = params[:page].to_i.clamp(1, @pages)
    change_ids = scope.group(:change_id).order(Arel.sql("MAX(recording_events.created_at) DESC, MAX(recording_events.id) DESC")).limit(30).offset((@page - 1) * 30).pluck(:change_id)
    selected = scope.where(change_id: change_ids)
    @event_counts = selected.group(:change_id).count
    ranked = selected.select("recording_events.id, ROW_NUMBER() OVER (PARTITION BY recording_events.change_id ORDER BY recording_events.created_at DESC, recording_events.id DESC) AS group_position")
    event_ids = RecordingEvent.from(ranked, :ranked_events).where("ranked_events.group_position <= ?", PREVIEW_SIZE).pluck(:id)
    @events = selected.where(id: event_ids).includes(:actor, :recordable, recording: :parent).order(created_at: :desc, id: :desc).to_a
    @history_entries = @events.slice_when { |event, next_event| event.change_id != next_event.change_id }.to_a
    @previous_events = previous_events_for(@events)
    ranked_events = @sheet_events.select("recording_events.id", "ROW_NUMBER() OVER (ORDER BY recording_events.created_at DESC, recording_events.id DESC) - 1 AS restore_count")
    @restore_counts = RecordingEvent.from(ranked_events, :ranked_events)
      .where("ranked_events.id IN (?)", @events.map(&:id))
      .pluck(Arel.sql("ranked_events.id"), Arel.sql("ranked_events.restore_count")).to_h
  end

  def change
    authorize @sheet, :history?
    @change_id = params[:change_id].to_i
    @offset = params[:offset].to_i.clamp(PREVIEW_SIZE, 10_000)
    events = filtered_scope.where(change_id: @change_id).where.not(change_type: "manual")
    raise ActiveRecord::RecordNotFound unless events.exists?
    @events = events.includes(:actor, :recordable, recording: :parent).order(created_at: :desc, id: :desc).offset(@offset).limit(BATCH_SIZE + 1).to_a
    @more = @events.length > BATCH_SIZE
    @events = @events.first(BATCH_SIZE)
    @previous_events = previous_events_for(@events)
  end

  def restore
    event = RecordingEvent.joins(:recording).where(recordings: { translation_tree_id: @sheet.translation_tree.id }).find(params[:id])
    authorize event
    changed = event.restore_sheet!(actor: current_user)
    redirect_to history_location, notice: changed.positive? ? "Sheet restored; #{changed} #{'recording'.pluralize(changed)} changed." : "The sheet already matches that point in history."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid, ArgumentError => error
    redirect_to history_location, alert: error.message.lines.first.to_s.first(300)
  end

  private

  def filtered_scope
    @languages = @sheet.active_languages.order(:name).to_a
    @language_ids = Array(params[:language_ids]).flatten.select { |id| @languages.any? { |language| language.id.to_s == id } }
    @query = params[:q].to_s.strip.first(200)
    @types = params.key?(:types) ? Array(params[:types]).flatten.select { |type| RecordingEvent::TYPE_FILTERS.key?(type) } : RecordingEvent::TYPE_FILTERS.keys
    @sheet_events = RecordingEvent.joins(:recording).where(recordings: { translation_tree_id: @sheet.translation_tree.id })
    @actors = User.where(id: @sheet_events.where.not(actor_id: nil).select(:actor_id)).order(:name)
    available_actor_ids = @actors.ids.map(&:to_s)
    @actor_ids = Array(params[:actor_ids]).flatten.select { |id| available_actor_ids.include?(id) }

    scope = @sheet_events
    if @language_ids.any?
      scope = scope.where(<<~SQL.squish, @language_ids)
        recording_events.recordable_type='TranslationKey' OR
        (recording_events.recordable_type='TextTranslation' AND EXISTS(
          SELECT 1 FROM text_translations WHERE text_translations.id=recording_events.recordable_id AND text_translations.language_id IN (?)
        ))
      SQL
    end
    scope = scope.where(recordable_type: @types.flat_map { |type| RecordingEvent::TYPE_FILTERS.fetch(type) })
    scope = scope.where(actor_id: @actor_ids) if @actor_ids.any?
    return scope if @query.blank?

    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
    scope.left_joins(:actor).where(<<~SQL.squish, pattern, pattern, pattern, pattern)
      users.name ILIKE ? OR EXISTS(
        SELECT 1 FROM translation_keys WHERE recording_events.recordable_type='TranslationKey' AND translation_keys.id=recording_events.recordable_id
        AND (translation_keys.name ILIKE ? OR translation_keys.description ILIKE ?)
      ) OR EXISTS(
        SELECT 1 FROM text_translations WHERE recording_events.recordable_type='TextTranslation' AND text_translations.id=recording_events.recordable_id
        AND text_translations.text ILIKE ?
      )
    SQL
  end

  def previous_events_for(events)
    previous = {}
    by_recording = {}
    RecordingEvent.where(recording_id: events.map(&:recording_id)).includes(:recordable).order(:recording_id, :id).each do |event|
      previous[event.id] = by_recording[event.recording_id]
      by_recording[event.recording_id] = event
    end
    previous
  end

  def recording_key_path(recording)
    parts = []
    while recording
      parts.unshift(recording.recordable.name)
      recording = recording.parent
    end
    parts.join(@sheet.delimiter)
  end
  helper_method :recording_key_path

  def history_location
    history_project_sheet_path(@project, @sheet, language_ids: params[:language_ids], q: params[:q], types: params[:types], actor_ids: params[:actor_ids])
  end

  def set_sheet
    @project = policy_scope(Project).find_by!(slug: params[:project_id])
    @sheet = policy_scope(@project.sheets).find_by!(slug: params[:sheet_id] || params[:id])
  end
end
