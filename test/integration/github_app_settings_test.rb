require 'test_helper'
require 'minitest/mock'

class GithubAppSettingsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @user.update!(role: :owner, email_verified_at: Time.current)
    sign_in @user
    @private_key = OpenSSL::PKey::RSA.new(2048).to_pem.strip
    @secret = SecureRandom.hex(32)
  end

  def save_configuration(**attributes)
    patch settings_github_app_path, params: {github_app_configuration: {app_id: '12345', private_key: @private_key, webhook_secret: @secret}.merge(attributes)}
  end

  test 'project admins connect with installation access without a personal GitHub identity' do
    save_configuration
    @user = users(:two)
    @user.update!(role: :member, email_verified_at: Time.current)
    sign_in @user
    @user.auth_identities.where(provider: 'github').delete_all
    project = Project.create!(name: 'Installation connection')
    project.project_memberships.create!(user: @user, role: 'admin')
    api = Minitest::Mock.new
    api.expect(:repository, {'full_name' => 'org/repo'})
    CatalogGithub.stub(:new, api) do
      assert_enqueued_with(job: CatalogSyncJob) do
        post connect_project_path(project), params: {repository: 'org/repo', installation_id: 77, locale_directory: 'config/locales'}
      end
    end
    api.verify
    assert_response :success
    assert_equal 'org/repo', project.reload.repository

    failing = Object.new
    def failing.repository = raise(CatalogGithub::Error, 'GitHub returned 404; check the App installation and permissions')
    CatalogGithub.stub(:new, failing) do
      assert_no_enqueued_jobs do
        post connect_project_path(project), params: {repository: 'org/not-accessible', installation_id: 78}
      end
    end
    assert_response :unprocessable_entity
    assert_equal 'org/repo', project.reload.repository
    assert_equal 77, project.installation_id

    project.project_memberships.find_by!(user: @user).update!(role: 'viewer')
    assert_no_enqueued_jobs do
      post connect_project_path(project), params: {repository: 'org/repo', installation_id: 77}
    end
    assert_response :forbidden
  end

  test 'global owner saves encrypted credentials and blank fields preserve them without exposing secrets' do
    save_configuration
    assert_redirected_to settings_github_app_path
    configuration = GithubAppConfiguration.find(1)
    assert_equal @private_key, configuration.private_key
    assert_not_includes configuration.read_attribute_before_type_cast(:private_key), 'BEGIN RSA PRIVATE KEY'
    assert_not_includes configuration.read_attribute_before_type_cast(:webhook_secret), @secret
    assert CatalogGithub.configured?
    save_configuration(private_key: '', webhook_secret: '')
    assert_redirected_to settings_github_app_path
    assert_equal @private_key, configuration.reload.private_key
    assert_equal @secret, configuration.webhook_secret
    get settings_github_app_path
    assert_select 'se-input[name="github_app_configuration[app_id]"][value="12345"]'
    assert_not_includes response.body, @secret
    assert_not_includes response.body, @private_key
    api = CatalogGithub.new(Project.new(installation_id: 77))
    api.stub(:request, ->(method, path, data, auth:) {
      assert_equal :post, method
      assert_equal '/app/installations/77/access_tokens', path
      assert_equal '12345', JSON.parse(Base64.urlsafe_decode64(auth.split('.')[1]))['iss']
      {'token' => 'test-installation-token'}
    }) { assert_equal 'test-installation-token', api.token }
  end

  test 'invalid credentials remain on form and members and admins cannot change them' do
    save_configuration(private_key: 'invalid', webhook_secret: 'short')
    assert_response :unprocessable_entity
    assert_select 'se-input[name="github_app_configuration[private_key]"][error*="valid RSA"]'
    assert_equal 0, GithubAppConfiguration.count
    users(:two).update!(role: :owner, email_verified_at: Time.current)
    @user.update!(role: :admin)
    save_configuration
    assert_redirected_to settings_users_path
    assert_equal 0, GithubAppConfiguration.count
    get settings_github_app_path
    assert_response :success
    assert_select 'form[action=?]', settings_github_app_path, count: 0
    @user.update!(role: :member)
    get settings_github_app_path
    assert_redirected_to projects_path
    save_configuration
    assert_equal 0, GithubAppConfiguration.count
  end

  test 'database configured webhook verifies signatures and isolates installations and repositories' do
    save_configuration
    project = Project.create!(name: 'Linked catalog', repository: 'example/repo', installation_id: 77, git_branch: 'trunk')
    sign_out @user
    send_event = lambda do |event, payload, secret = @secret|
      body = payload.to_json
      post '/github/webhook', params: body, headers: {'Content-Type'=>'application/json', 'X-GitHub-Event'=>event, 'X-Hub-Signature-256'=>"sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"}
    end
    send_event.call('ping', {})
    assert_response :accepted
    payload = {repository: {full_name: 'example/repo'}, installation: {id: 77}, ref: 'refs/heads/trunk'}
    assert_enqueued_with(job: CatalogSyncJob, args: [project.id]) { send_event.call('push', payload) }
    assert_no_enqueued_jobs { send_event.call('push', payload.merge(installation: {id: 78})) }
    assert_no_enqueued_jobs { send_event.call('push', payload.merge(repository: {full_name: 'other/repo'})) }
    assert_no_enqueued_jobs { send_event.call('push', payload, 'incorrect') }
    assert_response :unauthorized
    send_event.call('push', [])
    assert_response :bad_request
    pr = payload.merge(number: 9, action: 'opened', pull_request: {base: {ref: 'trunk'}})
    assert_enqueued_with(job: CatalogCheckJob, args: [project.id, 9]) { send_event.call('pull_request', pr) }
    assert_enqueued_with(job: CatalogTagJob, args: [project.id, 'v1.0.0']) { send_event.call('create', payload.merge(ref_type: 'tag', ref: 'v1.0.0')) }
  end
end
