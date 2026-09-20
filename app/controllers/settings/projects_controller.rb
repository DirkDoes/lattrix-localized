class Settings::ProjectsController < Settings::BaseController
  include TableResults

  def index
    authorize Project, :administration_index?
    @projects = table_results(policy_scope(Project).order(:name, :id), columns: %w[projects.name projects.slug])
  end
end
