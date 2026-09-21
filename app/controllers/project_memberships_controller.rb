class ProjectMembershipsController < ApplicationController
  layout "settings"
  after_action :verify_authorized
  before_action :set_membership

  def edit
    authorize @membership
    @role_options = policy(@membership).role_options
  end

  def update
    saved = @project.with_lock do
      @membership.reload
      authorize @membership
      @role_options = policy(@membership).role_options
      role = params.require(:project_membership).permit(:role)[:role]
      raise Pundit::NotAuthorizedError unless @role_options.include?(role)
      @membership.update!(role: role)
      if params.key?(:language_ids) || role != "translator"
        ids = role == "translator" ? Array(params[:language_ids]).reject(&:blank?).uniq : []
        raise ActiveRecord::RecordNotFound unless @project.languages.active.where(id: ids).count == ids.length
        @membership.membership_languages.destroy_all
        ids.each { |id| @membership.membership_languages.create!(language_id: id) }
      end
      true
    end
    if saved
      redirect_to membership_destination, notice: "Project role updated."
    else
      render :edit, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordInvalid
    render :edit, status: :unprocessable_entity
  end

  def destroy
    removed = @project.with_lock do
      @membership.reload
      authorize @membership
      @membership.destroy
    end
    redirect_to membership_destination,
      removed ? { notice: "Member removed from the project." } : { alert: @membership.errors.full_messages.to_sentence }
  end

  private

  def membership_destination
    policy(@project).members? ? members_project_path(@project) : projects_path
  end

  def set_membership
    @project = policy_scope(Project).find_by!(slug: params[:project_id])
    @membership = policy_scope(@project.project_memberships).find(params[:id])
  end
end
