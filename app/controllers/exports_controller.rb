class ExportsController < ApplicationController
  allow_unauthenticated_access
  after_action :verify_authorized
  before_action :load_project
  def create
    format = params[:export_format].to_s
    raise ArgumentError, "Choose an export format" unless %w[yaml json csv xlsx].include?(format)
    sheets = policy_scope(@project.sheets)
    ids = Array(params[:sheet_ids]).reject(&:blank?).uniq
    sheets = sheets.where(id: ids) if ids.any?
    raise ArgumentError, "Select accessible sheets" if sheets.none? || (ids.any? && sheets.count != ids.length)
    sheet_ids = sheets.pluck(:id)
    event = if params[:recording_event_id].present?
      raise ArgumentError, "Historical exports require one sheet" unless sheet_ids.one?
      RecordingEvent.joins(recording: :translation_tree).find_by(id: params[:recording_event_id], translation_trees: {sheet_id: sheet_ids.first}) || raise(ArgumentError, "Invalid history point")
    end
    languages = Array(params[:language_ids]).reject(&:blank?).uniq
    raise ArgumentError, "Invalid language selection" unless @project.languages.active.where(id: languages).count == languages.length
    set = @project.identifier_sets.find_by(id: params[:identifier_set_id]) if params[:identifier_set_id].present?
    raise ArgumentError, "Invalid identifier set" if params[:identifier_set_id].present? && !set
    set ||= @project.identifier_sets.order(:created_at).first
    session[:export_owner] ||= SecureRandom.hex(24)
    @project.with_lock do
      pending = ExportRequest.where(owner_key: session[:export_owner], user_id: current_user&.id, status: %w[queued running]).where("created_at > ?", 30.minutes.ago).first
      if pending
        raise ArgumentError, "An export is still running in another project" unless pending.project_id == @project.id
        return render json: {url: project_export_path(@project, pending)}
      end
      request = @project.export_requests.create!(user: current_user, owner_key: session[:export_owner], options: {format: format, sheet_ids: sheet_ids, language_ids: languages, identifier_set_id: set&.id, descriptions: params[:descriptions] == "1", recording_event_id: event&.id})
      ExportJob.perform_later(request.id)
      ExportCleanupJob.set(wait: 1.day).perform_later(request.id)
      render json: {url: project_export_path(@project, request)}
    end
  rescue ArgumentError => error
    render json: {error: error.message}, status: :unprocessable_entity
  end
  def show
    request = owned_request
    render json: {status: request.status, progress: request.progress, error: request.error, download: request.status == "ready" ? download_project_export_path(@project, request) : nil}
  end
  def destroy
    request = owned_request
    request.with_lock do
      request.update!(status: "cancelled")
      FileUtils.rm_f(request.path)
    end
    head :no_content
  end
  def download
    request = owned_request
    request.accessible_sheets
    return head :gone unless request.status == "ready" && request.path.file? && request.created_at > 1.day.ago
    send_file request.path, filename: request.filename, disposition: "attachment", type: Marcel::MimeType.for(name: request.filename)
  end
  private
  def load_project
    @project = policy_scope(Project).find_by!(slug: params[:project_id])
    authorize @project, :show?
  end
  def owned_request
    raise ActiveRecord::RecordNotFound unless session[:export_owner]
    @project.export_requests.where(owner_key: session[:export_owner], user_id: current_user&.id).find(params[:id])
  end
end
