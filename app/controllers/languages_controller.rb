class LanguagesController < ApplicationController
  after_action :verify_authorized
  def create = change_language(:create)
  def archive = change_language(:archive)
  def restore = change_language(:restore)

  private
  def change_language(operation)
    project = policy_scope(Project).find_by!(slug: params[:project_id])
    authorize project, :update?
    project.with_lock do
      raise ArgumentError, "Manage archived language files in the repository while GitHub is connected" if project.linked? && operation != :create
      raise ArgumentError, "Repair synchronization first" unless project.writable?
      if operation == :create
        language = project.languages.find_or_initialize_by(identifier: params.require(:identifier))
        language.pending_repository = true if project.linked? && (language.new_record? || !language.active?)
        language.update!(status: "active")
      else
        language = project.languages.find(params[:id])
        operation == :archive ? language.archive! : language.update!(status: "active")
      end
      CatalogWriter.new(project, actor: current_user).edit(expected: project.revision, summary: "Updated supported languages") { |writer| writer.refresh_categories }
    end
    render json: {location: settings_project_path(project)}
  rescue ArgumentError, ActiveRecord::RecordInvalid => error
    render json: {error: error.message}, status: :unprocessable_entity
  end
end
