class WorkspacesController < ApplicationController
  include TableResults
  layout "settings"
  before_action :set_workspace, only: [:show, :members]

  def index
    @memberships = current_user.workspace_memberships.includes(:workspace).order(:created_at)
    @workspace = Workspace.new
  end

  def create
    return head :forbidden if current_user.guest?
    @workspace = Workspace.new(params.require(:workspace).permit(:name, :slug, :visibility))
    Workspace.transaction do
      @workspace.save!
      @workspace.workspace_memberships.create!(user: current_user, role: "owner")
    end
    redirect_to workspace_path(@workspace), notice: "Workspace created."
  rescue ActiveRecord::RecordInvalid
    @memberships = current_user.workspace_memberships.includes(:workspace).order(:created_at)
    render :index, status: :unprocessable_entity
  end

  def show
  end

  def members
    raise ActiveRecord::RecordNotFound unless @membership
    @memberships = table_results(@workspace.workspace_memberships.joins(:user).includes(:user).order("users.name", "workspace_memberships.id"), columns: %w[users.name users.email])
  end

  private

  def set_workspace
    @workspace = Workspace.visible_to(current_user).find_by!(slug: params[:id])
    @membership = @workspace.workspace_memberships.find_by(user: current_user)
  end
end
