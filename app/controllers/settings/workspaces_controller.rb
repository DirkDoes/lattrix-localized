class Settings::WorkspacesController < Settings::BaseController
  include TableResults
  require_owner

  def index
    @workspaces = table_results(Workspace.order(:name, :id), columns: %w[workspaces.name workspaces.slug])
  end
end
