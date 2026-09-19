class WorkspaceInvitesController < ApplicationController
  include TableResults
  after_action :verify_authorized
  after_action :verify_policy_scoped, only: :index
  layout "settings"

  def index
    authorize WorkspaceInvite
    if params[:workspace_id]
      @workspace = policy_scope(Workspace).find_by!(slug: params[:workspace_id])
      authorize @workspace, :update?
      @invites = table_results(policy_scope(@workspace.workspace_invites, policy_scope_class: WorkspaceInvitePolicy::ManagementScope).includes(:invited_by).order(created_at: :desc, id: :desc), columns: %w[workspace_invites.email])
      render :manage
    else
      @invites = policy_scope(WorkspaceInvite).includes(:workspace).order(created_at: :desc)
    end
  end

  def create
    workspace = policy_scope(Workspace).find_by!(slug: params[:workspace_id])
    workspace.with_lock do
      raise ActiveRecord::RecordNotFound unless policy(workspace).members?
      authorize workspace, :update?
      email = params[:email].to_s.strip.downcase
      invite = workspace.workspace_invites.build(email: email, role: params[:role].presence || "viewer")
      authorize invite
      invite.valid?
      errors = invite.errors.reject { |error| error.attribute == :email && error.type == :taken }
      if errors.any?
        @workspace = workspace
        @memberships = table_results(policy_scope(workspace.workspace_memberships).joins(:user).includes(:user).order("users.name", "workspace_memberships.id"), columns: %w[users.name users.email])
        @invite_email = email
        @invite_role = invite.role
        @invite_error = "Enter a valid email address." if invite.errors[:email].any?
        @invite_role_error = "Choose Viewer or Translator." if invite.errors[:role].any?
        return render "workspaces/members", status: :unprocessable_entity
      end
      workspace.workspace_invites.find_or_create_by!(email: email) { |pending| pending.role = invite.role; pending.invited_by = current_user }
    end
    redirect_to members_workspace_path(workspace), notice: "User has been invited."
  end

  def destroy
    workspace = policy_scope(Workspace).find_by!(slug: params[:workspace_id])
    workspace.with_lock do
      invite = policy_scope(workspace.workspace_invites, policy_scope_class: WorkspaceInvitePolicy::ManagementScope).find(params[:id])
      authorize invite
      invite.destroy!
    end
    redirect_to workspace_workspace_invites_path(workspace), notice: "Invitation revoked."
  end

  def update
    invite = policy_scope(WorkspaceInvite).find(params[:id])
    authorize invite
    case params[:decision]
    when "accept"
      invite.accept!(current_user)
      redirect_to workspaces_path, notice: "Workspace invitation accepted."
    when "decline"
      invite.destroy!
      redirect_to workspace_invites_path, notice: "Workspace invitation declined."
    else
      head :unprocessable_entity
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => error
    redirect_to workspace_invites_path, alert: error.record.errors.full_messages.to_sentence
  end
end
