class ExportCleanupJob < ApplicationJob
  def perform(id)
    ExportRequest.find_by(id: id)&.destroy!
  end
end
