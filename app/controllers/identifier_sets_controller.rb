class IdentifierSetsController < ApplicationController
  after_action :verify_authorized
  def create
    save_set
  end
  def update
    save_set
  end
  private
  def save_set
    @project = policy_scope(Project).find_by!(slug: params[:project_id])
    authorize @project, :update?
    @project.with_lock do
      set = params[:id] ? @project.identifier_sets.find(params[:id]) : @project.identifier_sets.new
      fresh = set.new_record?
      set.update!(params.require(:identifier_set).permit(:name, :description))
      if fresh
        @project.languages.each { |language| set.language_identifiers.create!(language: language, identifier: language.identifier) }
      end
    end
    respond_to do |format|
      format.json { render json: {message: "Identifier set saved."} }
      format.html { redirect_to settings_project_path(@project), notice: "Identifier set saved." }
    end
  rescue ActiveRecord::RecordInvalid => error
    render json: {error: error.record.errors.full_messages.to_sentence}, status: :unprocessable_entity
  end
end
