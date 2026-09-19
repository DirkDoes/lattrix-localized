class ProjectsController < ApplicationController
  layout "settings"
  after_action :verify_authorized
  after_action :verify_policy_scoped, only: :index
  allow_unauthenticated_access only: [:index, :show, :translations]
  before_action :authenticate_private_project, only: [:index, :show, :translations]
  before_action :set_workspace

  def index
    authorize @workspace, :show?
    @projects = readable_projects.order(:name)
    @project = @workspace.projects.new
  end

  def create
    @project = @workspace.projects.new(params.require(:project).permit(:name, :slug, :visibility))
    authorize @project
    if @workspace.with_lock { @project.save }
      redirect_to workspace_project_path(@workspace, @project), notice: "Project created."
    else
      @projects = readable_projects.order(:name)
      render :index, status: :unprocessable_entity
    end
  end

  def show
    @project = readable_projects.find_by!(slug: params[:id])
    authorize @project
  end

  def translations
    show
  end

  private

  def authenticate_private_project
    return if current_user
    workspace = policy_scope(Workspace).find_by(slug: params[:workspace_id])
    public_page = workspace && (action_name == "index" || policy_scope(workspace.projects).exists?(slug: params[:id]))
    authenticate_user! unless public_page
  end

  def readable_projects
    policy_scope(@workspace.projects)
  end

  def set_workspace
    @workspace = policy_scope(Workspace).find_by!(slug: params[:workspace_id])
  end
end
