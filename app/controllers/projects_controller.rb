class ProjectsController < ApplicationController
  layout "settings"
  before_action :set_workspace

  def index
    @projects = readable_projects.order(:name)
    @project = @workspace.projects.new
  end

  def create
    return head :forbidden unless %w[admin owner].include?(@membership&.role)
    @project = @workspace.projects.new(params.require(:project).permit(:name, :slug, :visibility))
    if @project.save
      redirect_to workspace_project_path(@workspace, @project), notice: "Project created."
    else
      @projects = readable_projects.order(:name)
      render :index, status: :unprocessable_entity
    end
  end

  def show
    @project = readable_projects.find_by!(slug: params[:id])
  end

  def translations
    show
  end

  private

  def readable_projects
    @membership ? @workspace.projects : @workspace.projects.where(visibility: "public")
  end

  def set_workspace
    @workspace = Workspace.visible_to(current_user).find_by!(slug: params[:workspace_id])
    @membership = @workspace.workspace_memberships.find_by(user: current_user)
  end
end
