class ExportRequest < ApplicationRecord
  attribute :storage_key, :string, default: -> { SecureRandom.uuid }
  belongs_to :project
  belongs_to :user, optional: true
  validates :status, inclusion: {in: %w[queued running ready cancelled failed]}
  after_destroy { FileUtils.rm_f(path) }
  def path = Rails.root.join("storage", "exports", "#{storage_key.presence || id}.download")
  def accessible_sheets
    sheets = Pundit.policy_scope!(user, project.sheets).where(id: options.fetch("sheet_ids"))
    raise Pundit::NotAuthorizedError unless sheets.count == options.fetch("sheet_ids").length
    sheets.order(:name, :id).to_a
  end
end
