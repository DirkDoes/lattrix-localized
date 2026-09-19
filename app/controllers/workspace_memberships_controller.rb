class WorkspaceMembershipsController < ApplicationController
  layout "settings"
  after_action :verify_authorized
  before_action :set_membership

  def edit
    authorize @membership
    @role_options = policy(@membership).role_options
  end

  def update
    saved = @workspace.with_lock do
      @membership.reload
      authorize @membership
      @role_options = policy(@membership).role_options
      role = params.require(:workspace_membership).permit(:role)[:role]
      raise Pundit::NotAuthorizedError unless @role_options.include?(role)
      @membership.update(role: role)
    end
    if saved
      redirect_to membership_destination, notice: "Workspace role updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    removed = @workspace.with_lock do
      @membership.reload
      authorize @membership
      @membership.destroy
    end
    redirect_to membership_destination,
      removed ? { notice: "Member removed from the workspace." } : { alert: @membership.errors.full_messages.to_sentence }
  end

  private

  def membership_destination
    policy(@workspace).members? ? members_workspace_path(@workspace) : workspaces_path
  end

  def set_membership
    @workspace = policy_scope(Workspace).find_by!(slug: params[:workspace_id])
    @membership = policy_scope(@workspace.workspace_memberships).find(params[:id])
  end
end
