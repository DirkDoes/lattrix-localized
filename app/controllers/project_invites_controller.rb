class ProjectInvitesController < ApplicationController
  include TableResults
  after_action :verify_authorized
  after_action :verify_policy_scoped, only: :index
  layout "settings"

  def index
    authorize ProjectInvite
    if params[:project_id]
      @project = policy_scope(Project).find_by!(slug: params[:project_id])
      authorize @project, :update?
      @invites = table_results(policy_scope(@project.project_invites, policy_scope_class: ProjectInvitePolicy::ManagementScope).includes(:invited_by).order(created_at: :desc, id: :desc), columns: %w[project_invites.email])
      render :manage
    else
      @invites = policy_scope(ProjectInvite).includes(:project).order(created_at: :desc)
    end
  end

  def create
    project = policy_scope(Project).find_by!(slug: params[:project_id])
    project.with_lock do
      raise ActiveRecord::RecordNotFound unless policy(project).members?
      authorize project, :update?
      email = params[:email].to_s.strip.downcase
      invite = project.project_invites.build(email: email, role: params[:role].presence || "viewer")
      authorize invite
      invite.valid?
      errors = invite.errors.reject { |error| error.attribute == :email && error.type == :taken }
      if errors.any?
        @project = project
        @memberships = table_results(policy_scope(project.project_memberships).joins(:user).includes(:user).order("users.name", "project_memberships.id"), columns: %w[users.name users.email])
        @invite_email = email
        @invite_role = invite.role
        @invite_error = "Enter a valid email address." if invite.errors[:email].any?
        @invite_role_error = "Choose Viewer or Translator." if invite.errors[:role].any?
        return render "projects/members", status: :unprocessable_entity
      end
      project.project_invites.find_or_create_by!(email: email) { |pending| pending.role = invite.role; pending.invited_by = current_user }
    end
    redirect_to members_project_path(project), notice: "User has been invited."
  end

  def destroy
    project = policy_scope(Project).find_by!(slug: params[:project_id])
    project.with_lock do
      invite = policy_scope(project.project_invites, policy_scope_class: ProjectInvitePolicy::ManagementScope).find(params[:id])
      authorize invite
      invite.destroy!
    end
    redirect_to project_project_invites_path(project), notice: "Invitation revoked."
  end

  def update
    invite = policy_scope(ProjectInvite).find(params[:id])
    authorize invite
    case params[:decision]
    when "accept"
      invite.accept!(current_user)
      redirect_to projects_path, notice: "Project invitation accepted."
    when "decline"
      invite.destroy!
      redirect_to project_invites_path, notice: "Project invitation declined."
    else
      head :unprocessable_entity
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => error
    redirect_to project_invites_path, alert: error.record.errors.full_messages.to_sentence
  end
end
