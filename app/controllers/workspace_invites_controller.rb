class WorkspaceInvitesController < ApplicationController
  include TableResults
  layout "settings"

  def index
    @invites = WorkspaceInvite.where(email: current_user.email).includes(:workspace).order(created_at: :desc)
  end

  def create
    workspace = current_user.workspaces.find_by!(slug: params[:workspace_id])
    membership = workspace.workspace_memberships.find_by!(user: current_user)
    return head :forbidden unless membership.can_invite?

    email = params[:email].to_s.strip.downcase
    invite = workspace.workspace_invites.build(email: email)
    unless invite.valid? || invite.errors.of_kind?(:email, :taken)
      @membership = membership
      @workspace = workspace
      @memberships = table_results(workspace.workspace_memberships.joins(:user).includes(:user).order("users.name", "workspace_memberships.id"), columns: %w[users.name users.email])
      @invite_email = email
      @invite_error = "Enter a valid email address."
      return render "workspaces/members", status: :unprocessable_entity
    end
    workspace.workspace_invites.find_or_create_by!(email: email)
    redirect_to members_workspace_path(workspace), notice: "User has been invited."
  end

  def update
    invite = WorkspaceInvite.where(email: current_user.email).find(params[:id])
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
  end
end
