class RecordingEvent < ApplicationRecord
  ACTIONS = %w[created updated deleted].freeze
  TYPE_FILTERS = { "key" => %w[TranslationKey], "translation" => %w[TextTranslation] }.freeze

  belongs_to :recording
  belongs_to :actor, class_name: "User", optional: true
  delegated_type :recordable, types: %w[TranslationKey TextTranslation]

  validates :action, inclusion: { in: ACTIONS }
  before_update { raise ActiveRecord::ReadOnlyRecord, "History is immutable" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "History is immutable" }

  delegate :translation_tree, to: :recording

  def row_partial
    "recording_events/recordables/#{recordable_type.underscore}"
  end

  def restore_sheet!(actor:)
    translation_tree.with_lock do
      states = RecordingSnapshot.new(self).states
      restored_at = Time.current
      changes = states.filter_map do |state|
        item = state.recording
        desired = { recordable_type: state.recordable_type, recordable_id: state.recordable_id, deleted_at: state.active ? nil : restored_at }
        next if item.recordable_type == desired[:recordable_type] && item.recordable_id == desired[:recordable_id] && item.deleted_at? == desired[:deleted_at].present?
        { recording: item, desired: desired, was_deleted: item.deleted_at? }
      end

      changes.each { |change| change[:recording].update!(deleted_at: restored_at) unless change[:recording].deleted_at? }
      changes_by_recording = changes.index_by { |change| change[:recording].id }
      Recording.descendants_first(changes.map { |change| change[:recording] }).reverse_each do |item|
        item.update!(changes_by_recording.fetch(item.id)[:desired])
      end
      change_id = nil
      Recording.descendants_first(changes.map { |change| change[:recording] }).each do |item|
        change = changes_by_recording.fetch(item.id)
        action = if item.deleted_at?
          "deleted"
        elsif change[:was_deleted]
          "created"
        else
          "updated"
        end
        event = item.record_event!(action, actor: actor, reverted: true, created_at: restored_at, change_id: change_id)
        change_id ||= event.change_id
      end
      changes.length
    end
  end
end
