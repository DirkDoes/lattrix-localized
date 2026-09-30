class Settings::GithubAppsController < Settings::BaseController
  skip_after_action :verify_policy_scoped # Singleton settings have no index/list scope.
  def show
    authorize GithubAppConfiguration
    @configuration = GithubAppConfiguration.current
  end

  def update
    authorize GithubAppConfiguration
    @configuration = GithubAppConfiguration.current
    attributes = params.require(:github_app_configuration).permit(:app_id, :private_key, :webhook_secret)
    attributes.delete(:private_key) if attributes[:private_key].blank?
    attributes.delete(:webhook_secret) if attributes[:webhook_secret].blank?
    if @configuration.update(attributes)
      redirect_to settings_github_app_path, notice: 'GitHub App configuration saved.'
    else
      render :show, status: :unprocessable_entity
    end
  end
end
