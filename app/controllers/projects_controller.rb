class ProjectsController < ApplicationController
  include TableResults
  after_action :verify_authorized
  after_action :verify_policy_scoped, only: [:index, :members]
  layout "settings"
  allow_unauthenticated_access only: [:show]
  before_action :authenticate_private_project, only: [:show]
  before_action :set_project, only: [:show, :members, :settings, :update, :destroy]
  before_action :require_project_admin, only: [:settings, :update]

  def index
    authorize Project
    @memberships = policy_scope(current_user.project_memberships).includes(:project).order(:created_at)
    @project = Project.new
  end

  def create
    authorize Project
    @project = Project.new(params.require(:project).permit(:name, :slug, :visibility))
    current_user.with_lock do
      unless policy(Project).new?
        @project.errors.add(:base, "Members can own at most three projects before creating another.")
        raise ActiveRecord::RecordInvalid, @project
      end
      @project.save!
      @project.project_memberships.create!(user: current_user, role: "owner")
    end
    redirect_to project_path(@project), notice: "Project created."
  rescue ActiveRecord::RecordInvalid
    @memberships = policy_scope(current_user.project_memberships).includes(:project).order(:created_at)
    render :index, status: :unprocessable_entity
  end

  def show
    authorize @project
    redirect_to project_sheets_path(@project)
  end


  def members
    raise ActiveRecord::RecordNotFound unless policy(@project).members?
    authorize @project, :members?
    columns = policy(@project).view_member_emails? ? %w[users.name users.email] : %w[users.name]
    @memberships = table_results(policy_scope(@project.project_memberships).joins(:user).includes(:user).order("users.name", "project_memberships.id"), columns: columns)
  end

  def settings
  end

  def update
    saved = @project.with_lock do
      authorize @project, :update?
      @original_slug = @project.slug
      attributes = params.require(:project).permit(:name, :visibility, :slug, :advanced_languages)
      slug_changes = attributes.key?(:slug) && attributes[:slug].to_s.strip.downcase != @project.slug
      authorize @project, :change_slug? if slug_changes
      visibility_changes = attributes.key?(:visibility) && attributes[:visibility] != @project.visibility
      authorize @project, :change_visibility? if visibility_changes
      @project.assign_attributes(attributes)
      if @project.valid? && ((visibility_changes && params[:confirm_visibility] != "1") || (slug_changes && params[:confirm_slug] != "1"))
        @confirm_visibility = visibility_changes
        @confirm_slug = slug_changes
        @pending_attributes = attributes
        false
      else
        @project.save
      end
    end
    unless saved
      @requested_slug = @project.slug
      @project.slug = @original_slug
    end
    if @confirm_visibility || @confirm_slug
      render :settings
    elsif saved
      redirect_to settings_project_path(@project), notice: "Project updated."
    else
      render :settings, status: :unprocessable_entity
    end
  end

  def destroy
    removed = @project.with_lock do
      authorize @project
      if params[:confirmation] != "DELETE PROJECT"
        @delete_error = "Type DELETE PROJECT exactly to confirm deletion."
        false
      else
        @project.destroy
      end
    end
    if removed
      redirect_to projects_path, notice: "Project permanently deleted."
    else
      @delete_error ||= @project.errors.full_messages.to_sentence
      render :settings, status: :unprocessable_entity
    end
  end

  private

  def authenticate_private_project
    authenticate_user! unless current_user || policy_scope(Project).exists?(slug: params[:id])
  end

  def require_project_admin
    authorize @project, :update?
  end

  def set_project
    @project = policy_scope(Project).find_by!(slug: params[:id])
  end
end
