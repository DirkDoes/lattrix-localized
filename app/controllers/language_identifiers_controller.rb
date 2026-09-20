class LanguageIdentifiersController < ApplicationController
  after_action :verify_authorized
  def update
    project = policy_scope(Project).find_by!(slug: params[:project_id])
    authorize project, :update?
    mapping = LanguageIdentifier.joins(:identifier_set).where(identifier_sets: {project_id: project.id}).find(params[:id])
    project.with_lock { mapping.update!(params.require(:language_identifier).permit(:identifier)) }
    render json: {message: "Identifier saved."}
  rescue ActiveRecord::RecordInvalid => error
    render json: {error: error.record.errors.full_messages.to_sentence}, status: :unprocessable_entity
  end
end
