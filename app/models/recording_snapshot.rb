class RecordingSnapshot
  State = Data.define(:recording, :event, :active) do
    delegate :id, :parent_id, to: :recording

    def recordable = event&.recordable || recording.recordable
    def recordable_type = event&.recordable_type || recording.recordable_type
    def recordable_id = event&.recordable_id || recording.recordable_id
    def translation_key? = recordable_type == "TranslationKey"
    def text_translation? = recordable_type == "TextTranslation"
  end

  attr_reader :states

  def initialize(event)
    recordings = event.translation_tree.recordings.includes(:recordable).to_a
    targets = RecordingEvent.where(recording_id: recordings.map(&:id))
      .where("created_at < ? OR (created_at = ? AND id <= ?)", event.created_at, event.created_at, event.id)
      .includes(:recordable).order(:recording_id, :created_at, :id).group_by(&:recording_id).transform_values(&:last)
    by_id = recordings.index_by(&:id)
    active = {}
    resolve_active = lambda do |recording|
      active.fetch(recording.id) do
        target = targets[recording.id]
        active[recording.id] = target.present? && target.deleted_at.nil? && (!recording.parent_id || resolve_active.call(by_id.fetch(recording.parent_id)))
      end
    end
    @states = recordings.map { |recording| State.new(recording:, event: targets[recording.id], active: resolve_active.call(recording)) }
  end

  def active_recordings = states.select(&:active)
end
