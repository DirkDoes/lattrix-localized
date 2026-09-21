class DeleteLanguageJob < ApplicationJob
  queue_as :default

  def perform(language_id)
    language = Language.find_by(id: language_id)
    return unless language&.pending_deletion?

    language.with_lock do
      payload_ids = TextTranslation.where(language_id: language.id).pluck(:id)
      RecordingEvent.where(recordable_type: "TextTranslation", recordable_id: payload_ids).delete_all
      Recording.where(recordable_type: "TextTranslation", recordable_id: payload_ids).delete_all
      TextTranslation.transaction do
        TextTranslation.connection.execute("SET LOCAL app.purge_language='on'")
        TextTranslation.where(id: payload_ids).delete_all
      end
      language.destroy!
    end
  end
end
