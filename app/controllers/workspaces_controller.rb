class WorkspacesController < ApplicationController
  include TableResults
  after_action :verify_authorized
  after_action :verify_policy_scoped, only: [:index, :members]
  layout "settings"
  allow_unauthenticated_access only: :show
  before_action :authenticate_private_workspace, only: :show
  before_action :set_workspace, only: [:show, :members, :settings, :update, :destroy]
  before_action :require_workspace_admin, only: [:settings, :update]

  def index
    authorize Workspace
    @memberships = policy_scope(current_user.workspace_memberships).includes(:workspace).order(:created_at)
    @workspace = Workspace.new
  end

  def create
    authorize Workspace
    @workspace = Workspace.new(params.require(:workspace).permit(:name, :slug, :visibility))
    current_user.with_lock do
      unless policy(Workspace).new?
        @workspace.errors.add(:base, "Members can own at most three workspaces before creating another.")
        raise ActiveRecord::RecordInvalid, @workspace
      end
      @workspace.save!
      @workspace.workspace_memberships.create!(user: current_user, role: "owner")
    end
    redirect_to workspace_path(@workspace), notice: "Workspace created."
  rescue ActiveRecord::RecordInvalid
    @memberships = policy_scope(current_user.workspace_memberships).includes(:workspace).order(:created_at)
    render :index, status: :unprocessable_entity
  end

  def show
    authorize @workspace
  end

  def members
    raise ActiveRecord::RecordNotFound unless policy(@workspace).members?
    authorize @workspace, :members?
    columns = policy(@workspace).view_member_emails? ? %w[users.name users.email] : %w[users.name]
    @memberships = table_results(policy_scope(@workspace.workspace_memberships).joins(:user).includes(:user).order("users.name", "workspace_memberships.id"), columns: columns)
  end

  def settings
  end

  def update
    saved = @workspace.with_lock do
      authorize @workspace, :update?
      @original_slug = @workspace.slug
      attributes = params.require(:workspace).permit(:name, :visibility, :slug)
      slug_changes = attributes.key?(:slug) && attributes[:slug].to_s.strip.downcase != @workspace.slug
      authorize @workspace, :change_slug? if slug_changes
      visibility_changes = attributes.key?(:visibility) && attributes[:visibility] != @workspace.visibility
      authorize @workspace, :change_visibility? if visibility_changes
      @workspace.assign_attributes(attributes)
      if @workspace.valid? && ((visibility_changes && params[:confirm_visibility] != "1") || (slug_changes && params[:confirm_slug] != "1"))
        @confirm_visibility = visibility_changes
        @confirm_slug = slug_changes
        @pending_attributes = attributes
        false
      else
        @workspace.save
      end
    end
    unless saved
      @requested_slug = @workspace.slug
      @workspace.slug = @original_slug
    end
    if @confirm_visibility || @confirm_slug
      render :settings
    elsif saved
      redirect_to settings_workspace_path(@workspace), notice: "Workspace updated."
    else
      render :settings, status: :unprocessable_entity
    end
  end

  def destroy
    removed = @workspace.with_lock do
      authorize @workspace
      if params[:confirmation] != "DELETE WORKSPACE"
        @delete_error = "Type DELETE WORKSPACE exactly to confirm deletion."
        false
      else
        @workspace.destroy
      end
    end
    if removed
      redirect_to workspaces_path, notice: "Workspace permanently deleted."
    else
      @delete_error ||= @workspace.errors.full_messages.to_sentence
      render :settings, status: :unprocessable_entity
    end
  end

  private

  def authenticate_private_workspace
    authenticate_user! unless current_user || policy_scope(Workspace).exists?(slug: params[:id])
  end

  def require_workspace_admin
    authorize @workspace, :update?
  end

  def set_workspace
    @workspace = policy_scope(Workspace).find_by!(slug: params[:id])
  end
end
