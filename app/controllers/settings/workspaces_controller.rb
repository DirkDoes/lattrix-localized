class Settings::WorkspacesController < Settings::BaseController
  include TableResults

  def index
    authorize Workspace, :administration_index?
    @workspaces = table_results(policy_scope(Workspace).order(:name, :id), columns: %w[workspaces.name workspaces.slug])
  end
end
