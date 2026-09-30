require "test_helper"
class CatalogFlowTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current, role: :member)
    @project = Project.create!(name: "Catalog flow", visibility: "public")
    @membership = @project.project_memberships.create!(user: @user, role: "admin")
    @nl = @project.languages.create!(identifier: "nl")
    sign_in @user
  end
  def change(**params)
    post catalog_change_project_path(@project), params: {revision: @project.reload.revision, **params}, as: :json
  end
  test "cell statuses use one severity icon and invalid reviewed translations stay in review filter" do
    change(operation: 'add', path: 'greeting')
    key = CatalogState.new(@project).keys.sole
    change(operation: 'translate', node_id: key.id, locale: 'en', value: 'Hello %{name}')
    change(operation: 'translate', node_id: key.id, locale: 'nl', value: 'Hallo')
    state = CatalogState.new(@project, pending: true)
    value = state.translation(key.id, 'nl')
    assert_equal state.source_digest(key), CatalogReview.find_by!(catalog_node_id: value.id).source_digest
    get translations_project_path(@project), params: {locale: 'nl', status: 'review'}
    assert_select '.catalog-key se-code', text: 'greeting'
    assert_select '.catalog-value se-badge', count: 0
    assert_select '.catalog-status-icon--error', count: 1
    assert_select '.catalog-status-icon--warning', count: 0
    assert_select '.translation-cell > .catalog-cell-status se-tooltip', count: 1
    assert_select '.catalog-status-icon[aria-label*="Placeholders must match"]'
    change(operation: 'translate', node_id: key.id, locale: 'nl', value: 'Hallo %{name}')
    get translations_project_path(@project), params: {locale: 'nl'}
    assert_select '.catalog-status-icon--error', count: 0
    assert_select '.catalog-status-icon--warning', count: 0
    change(operation: 'translate', node_id: key.id, locale: 'en', value: 'Welcome %{name}')
    get translations_project_path(@project), params: {locale: 'nl', status: 'review'}
    assert_select '.catalog-status-icon--warning', count: 1
    change(operation: 'translate', node_id: key.id, locale: 'nl', value: 'Welkom %{name}')
    get translations_project_path(@project), params: {locale: 'nl', status: 'review'}
    assert_select 'se-list-row', count: 0
    change(operation: 'translate', node_id: key.id, locale: 'en', value: 'Invalid %{count}')
    get translations_project_path(@project), params: {locale: 'en', status: 'review'}
    assert_select '.catalog-key se-code', text: 'greeting'
    assert_select '.catalog-status-icon--error', count: 2
  end
  test "plural completeness belongs to the parent and individual errors stay on the form" do
    change(operation: 'add', path: 'notifications', kind: 'plural')
    state = CatalogState.new(@project, pending: true)
    parent = state.keys.find { |key| key.payload.kind == 'plural' }
    one, other = %w[one other].map { |name| state.children(parent.id).find { |key| key.payload.name == name } }
    change(operation: 'translate', node_id: one.id, locale: 'en', value: 'One notification')
    get translations_project_path(@project), params: {locale: 'nl'}
    assert_select "[data-catalog-status='#{parent.id}-en'] .catalog-status-icon--error", count: 1
    assert_select "[data-catalog-status='#{one.id}-en'] .catalog-status-icon", count: 0
    assert_select "[data-catalog-status='#{other.id}-en'] .catalog-status-icon", count: 0
    assert_select '[data-project-header-target="original"] se-title[level="page"]'
    assert_select '[data-project-header-target="compact"][hidden] se-title[level="section"]'
    change(operation: 'translate', inline: '1', node_id: other.id, locale: 'en', value: 'Notifications')
    statuses = response.parsed_body.fetch('statuses').index_by { |status| status['id'] }
    assert_not_includes statuses.fetch("#{parent.id}-en")['html'], 'catalog-status-icon'
    assert_includes statuses.fetch("#{other.id}-en")['html'], 'This plural form requires %{count}'
    get translations_project_path(@project), params: {locale: 'nl'}
    assert_select "[data-catalog-status='#{parent.id}-en'] .catalog-status-icon", count: 0
    assert_select "[data-catalog-status='#{other.id}-en'] .catalog-status-icon--error", count: 1
  end
  test "parent rows are secondary and plural cells follow each displayed language" do
    @project.languages.create!(identifier: 'ar')
    change(operation: 'add', path: 'account.email')
    change(operation: 'add', path: 'notifications', kind: 'plural')
    state = CatalogState.new(@project, pending: true)
    get translations_project_path(@project), params: {locale: 'ar'}
    assert_select 'se-list-row[variant="secondary"]', count: 2
    assert_select 'se-list-row:not([variant])', count: 7
    %w[zero two few many].each do |name|
      key = state.keys.find { |item| state.path(item) == "notifications.#{name}" }
      assert_select "[data-catalog-cell-node-value='#{key.id}'][data-catalog-cell-locale-value='en']", count: 0
      assert_select "[data-catalog-cell-node-value='#{key.id}'][data-catalog-cell-locale-value='ar']", count: 1
    end
    assert_select '[aria-label="This plural form is not used by English"]', text: '—', count: 4
    get translations_project_path(@project), params: {locale: 'nl'}
    assert_select 'se-list-row', count: 5
    assert_select '.catalog-key se-code', text: /\A(zero|two|few|many)\z/, count: 0
    zero = state.keys.find { |item| state.path(item) == 'notifications.zero' }
    change(operation: 'translate', node_id: zero.id, locale: 'en', value: 'No notifications')
    assert_response :unprocessable_entity
    assert_includes response.parsed_body['error'], 'not used by English'
  end
  test "inline editing returns safe text, refreshed status and revision without navigation" do
    change(operation: "add", path: "account.email")
    key = @project.catalog_nodes.where(payload_type: "CatalogKey", deleted: false).detect { |node| node.payload.name == "email" }
    get translations_project_path(@project)
    assert_select 'se-collection[dividers="1"][guides]'
    assert_select '.catalog-key se-code', text: 'email'
    assert_select '.catalog-key se-code', text: 'account.email', count: 0
    assert_select '.catalog-key se-badge', count: 0
    assert_select '[data-controller="catalog-cell"] [data-catalog-cell-target="editor"]:not([hidden])', count: 2
    change(operation: "translate", inline: "1", node_id: key.id, locale: "en", value: '<script>x</script> %{name}')
    assert_response :success
    result = response.parsed_body
    assert_equal @project.reload.revision, result['revision']
    assert_includes result['html'], '&lt;script&gt;'
    assert_includes result['html'], 'translation-wildcard'
    assert result['statuses'].any? { |status| status['id'] == "#{key.id}-nl" }
    assert_nil result['location']
    post catalog_change_project_path(@project), params: {operation: 'translate', inline: '1', revision: result['revision'] - 1, node_id: key.id, locale: 'en', value: 'stale'}, as: :json
    assert_response :conflict
    assert_equal '<script>x</script> %{name}', CatalogState.new(@project, pending: true).translation(key.id, 'en').payload.value
    change(operation: 'translate', inline: '1', node_id: key.id, locale: 'en', value: '')
    assert_response :success
    assert_equal '', response.parsed_body['value']
    change(operation: 'add', path: 'notifications', kind: 'plural')
    state = CatalogState.new(@project, pending: true)
    one = state.keys.find { |item| state.path(item) == 'notifications.one' }
    change(operation: 'translate', inline: '1', node_id: one.id, locale: 'en', value: 'One notification')
    assert_response :success
    assert_equal (state.children(state.plural_parent(one).id).count(&:key?) + 1) * 2, response.parsed_body['statuses'].size
  end
  test "create edit history and export use one catalog with preserved validation errors" do
    get translations_project_path(@project)
    assert_response :success
    assert_select "se-list-header", count: 0
    change(operation: "add", path: "greeting")
    assert_response :success
    key = @project.catalog_nodes.where(payload_type: "CatalogKey", deleted: false).sole
    change(operation: "translate", node_id: key.id, locale: "en", value: "Hello %{name}")
    assert_response :success
    change(operation: "translate", node_id: key.id, locale: "nl", value: "Hallo %{name}")
    get translations_project_path(@project)
    assert_select ".translation-wildcard", text: "%{name}", count: 2
    get history_project_path(@project)
    assert_response :success
    assert_not_includes response.body, @user.email
    get export_project_path(@project), params: {format_name: "csv"}
    assert_response :success
    assert_includes response.body, "greeting,Hello %{name},Hallo %{name}"
    change(operation: "add", path: "bad..key")
    assert_response :unprocessable_entity
    assert response.parsed_body["error"].present?
  end
  test "viewers cannot see history and translators only edit assigned locales" do
    change(operation: "add", path: "greeting")
    key = @project.catalog_nodes.where(payload_type: "CatalogKey", deleted: false).sole
    change(operation: "translate", node_id: key.id, locale: "en", value: "Hello")
    @membership.update!(role: "viewer")
    get history_project_path(@project)
    assert_response :forbidden
    change(operation: "translate", node_id: key.id, locale: "en", value: "Bad")
    assert_response :forbidden
    @membership.update!(role: "translator")
    @membership.languages << @nl
    get history_project_path(@project)
    assert_response :success
    change(operation: "translate", node_id: key.id, locale: "nl", value: "Hallo")
    assert_response :success
    change(operation: "translate", node_id: key.id, locale: "en", value: "Bad")
    assert_response :forbidden
    change(operation: "delete", node_id: key.id)
    assert_response :forbidden
  end
  test "public access exposes accepted translations but no draft history or edit controls" do
    sign_out @user
    get translations_project_path(@project)
    assert_response :success
    assert_select "se-button[data-open-modal=catalog-add-key]", count: 0
    @project.update!(visibility: "private")
    get translations_project_path(@project)
    assert_response :not_found
  end
  test "standard languages and export showcase have no removed settings" do
    post project_languages_path(@project), params: {identifier: "en-GB"}, as: :json
    assert_response :success
    assert @project.languages.exists?(identifier: "en-GB")
    post project_languages_path(@project), params: {identifier: "made-up"}, as: :json
    assert_response :unprocessable_entity
    get import_export_path
    assert_response :success
    assert_select "se-code-editor[language=yaml]", count: 2
    assert_not_includes response.body, "Change sheet settings"
    get import_export_path(export_format: "csv")
    assert_select ".format-preview-files--single"
    assert_select "se-code-editor[language=csv]"
  end
  test "unsigned github webhook cannot enqueue synchronization" do
    assert_no_enqueued_jobs { post "/github/webhook", params: {repository: {full_name: "example/repo"}}, as: :json }
    assert_response :unauthorized
  end

  test "translation batches append rows and filters select incomplete review and plural values" do
    writer = CatalogWriter.new(@project, actor: @user)
    writer.edit(expected: @project.revision) { |edit| 45.times { |i| edit.add_key("item_#{i.to_s.rjust(2, '0')}") }; edit.add_key("notifications", kind: "plural") }
    state = CatalogState.new(@project)
    translated = state.keys.find { |key| key.payload.name == "item_00" }
    writer.edit(expected: @project.reload.revision) { |edit| edit.translate(translated.id, "en", "Name"); edit.translate(translated.id, "nl", "Naam") }
    get translations_project_path(@project), params: {locale: "nl"}
    assert_select "#catalog-rows > se-list-row", count: 40
    assert_select "[data-controller=catalog-more]", count: 1
    assert_select "se-list-header se-select[data-catalog-locale][size=small]", count: 1
    get translations_project_path(@project), params: {page: 2, locale: "nl"}, headers: {"Accept"=>"text/vnd.turbo-stream.html"}
    assert_response :success
    assert_select "turbo-stream[action=append][target=catalog-rows]", count: 1
    assert_select "turbo-stream[target=catalog-rows] se-list-row", count: 8
    get translations_project_path(@project), params: {status: "review", locale: "nl"}
    assert_select "#catalog-rows > se-list-row", count: 0
    writer.edit(expected: @project.reload.revision) { |edit| edit.translate(translated.id, "en", "Full name") }
    get translations_project_path(@project), params: {status: "review", locale: "nl"}
    assert_select "#catalog-rows > se-list-row", count: 1
    get translations_project_path(@project), params: {status: "incomplete", locale: "nl"}
    assert_select "#catalog-rows se-code", text: "item_00", count: 0
    get translations_project_path(@project), params: {kind: "plural", locale: "nl"}
    assert_select "#catalog-rows > se-list-row", count: 3
  end

  test "history is a collapsed paginated table with bounded event batches" do
    CatalogWriter.new(@project, actor: @user).edit(expected: @project.revision) { |edit| 35.times { |i| edit.add_key("key_#{i}") } }
    change_set = @project.catalog_change_sets.last
    get history_project_path(@project)
    assert_select "se-collapsible", count: 0
    assert_select "se-collection > se-list-row[collapsed]", count: 1
    assert_select "se-collection > se-list-row[level='1'] .history-description", count: 10
    assert_select "se-menu[data-catalog-history-menu]", count: 1
    assert_select "se-pagination", count: 1
    get history_events_project_path(@project), params: {change_set_id: change_set.id, offset: 10}
    assert_response :success
    assert_select "turbo-stream[action=before] .history-description", count: 20
    assert_select "[data-history-more]", count: 1
    get history_events_project_path(@project), params: {change_set_id: change_set.id, offset: 30}
    assert_select "turbo-stream[action=before] .history-description", count: 5
    assert_select "[data-history-more]", count: 0
  end

  test "source language changes preserve values and reject missing translations and unauthorized changes" do
    writer = CatalogWriter.new(@project, actor: @user)
    writer.edit(expected: @project.revision) { |edit| edit.add_key("name") }
    key = CatalogState.new(@project).keys.sole
    writer.edit(expected: @project.reload.revision) { |edit| edit.translate(key.id, "en", "Name") }
    post source_locale_project_path(@project), params: {source_locale: "nl", revision: @project.reload.revision}, as: :json
    assert_response :unprocessable_entity
    assert_equal "en", @project.reload.source_locale
    writer.edit(expected: @project.revision) { |edit| edit.translate(key.id, "nl", "Naam") }
    post source_locale_project_path(@project), params: {source_locale: "nl", revision: @project.reload.revision}, as: :json
    assert_response :success
    assert_equal "nl", @project.reload.source_locale
    assert_equal "Name", CatalogState.new(@project).translation(key.id, "en").payload.value
    @membership.update!(role: "translator")
    post source_locale_project_path(@project), params: {source_locale: "en", revision: @project.revision}, as: :json
    assert_response :forbidden
  end

  test "signed push is scoped to the installation repository and configured branch" do
    original = ENV["GH_WEBHOOK_SECRET"]
    ENV["GH_WEBHOOK_SECRET"] = "test-only-webhook-secret"
    @project.update!(repository: "example/repo", installation_id: 42, git_branch: "trunk")
    body = {repository: {full_name: "example/repo"}, installation: {id: 42}, ref: "refs/heads/trunk"}.to_json
    headers = {"Content-Type"=>"application/json", "X-GitHub-Event"=>"push", "X-Hub-Signature-256"=>"sha256=#{OpenSSL::HMAC.hexdigest('SHA256', ENV['GH_WEBHOOK_SECRET'], body)}"}
    assert_enqueued_with(job: CatalogSyncJob, args: [@project.id]) { post "/github/webhook", params: body, headers: headers }
    assert_response :accepted
    assert_no_enqueued_jobs { post "/github/webhook", params: body + " ", headers: headers }
    assert_response :unauthorized
  ensure
    ENV["GH_WEBHOOK_SECRET"] = original
  end
end
