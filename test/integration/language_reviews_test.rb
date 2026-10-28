require "test_helper"

class LanguageReviewsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current, role: :member)
    @project = Project.create!(name: "Imported translations", visibility: "public")
    @membership = @project.project_memberships.create!(user: @user, role: "admin")
    CatalogReconcile.new(@project, {
      "en" => "en:\n  greeting: Hello %{name}\n  farewell: Bye\n  invalid: For %{name}\n  missing: Only source\n",
      "nl" => "nl:\n  greeting: Hallo %{name}\n  farewell: Dag\n  invalid: Voor %{name}\n",
      "fr" => "fr:\n  greeting: Bonjour %{name}\n"
    }, sha: "initial").apply!
    @nl = @project.languages.find_by!(identifier: "nl")
    sign_in @user
  end

  def approve(language = @nl, revision: @project.reload.revision)
    post approve_all_project_language_path(@project, language), params: {revision: revision}, as: :json
  end

  test "bulk approval preserves imported strings and only reviews the selected language" do
    state = CatalogState.new(@project)
    invalid = state.keys.find { |key| state.path(key) == "invalid" }
    CatalogWriter.new(@project).edit(expected: @project.revision) { |w| w.translate(invalid.id, "nl", "Fout") }
    CatalogReview.delete_all
    @project.update!(repository: "example/translations")
    before = CatalogExport.new(@project).values
    assert_difference "CatalogReview.count", 3 do
      assert_no_difference ["CatalogText.count", "CatalogDraft.count", "CatalogChangeSet.count", "CatalogEvent.count"] do
        approve
        assert_response :success
      end
    end
    assert_equal settings_project_path(@project), response.parsed_body["location"]
    assert_equal "All existing Dutch translations marked as reviewed.", flash[:notice]
    assert_equal before, CatalogExport.new(@project).values
    state = CatalogState.new(@project, pending: true)
    state.texts.each do |value|
      review = CatalogReview.find_by(catalog_node_id: value.id)
      if value.payload.locale == "nl"
        assert_equal @user.id, review.actor_id
        assert_equal value.payload.id, review.translation_payload_id
        assert_equal state.source_digest(state.items.fetch(value.parent_id)), review.source_digest
      else
        assert_nil review
      end
    end
    assert_no_difference "CatalogReview.count" do
      approve
      assert_response :success
    end
    get translations_project_path(@project), params: {locale: "nl"}
    assert_select '.catalog-status-icon[aria-label*="Needs review"]', count: 0
    assert_select '.catalog-status-icon[aria-label*="Placeholders must match"]', count: 1

    key = state.keys.find { |item| state.path(item) == "greeting" }
    CatalogWriter.new(@project).edit(expected: @project.reload.revision) { |w| w.translate(key.id, "en", "Welcome %{name}") }
    get translations_project_path(@project), params: {locale: "nl"}
    assert_select '.catalog-status-icon[aria-label*="Needs review"]', count: 1
  end

  test "language menus keep lifecycle actions and restrict approval to active target languages" do
    get settings_project_path(@project)
    assert_response :success
    assert_select 'se-menu[data-language-actions][icon-only][label="Actions for Dutch"]' do |menus|
      assert_equal %w[approve lifecycle], JSON.parse(menus.sole["options"]).pluck("id")
    end
    assert_select 'se-menu[data-language-actions][label="Actions for English"]', count: 0
    assert_select "se-modal#language-approve-#{@nl.id} form[action=?]", approve_all_project_language_path(@project, @nl)
    @nl.archive!
    get settings_project_path(@project)
    assert_select 'se-menu[data-language-actions][label="Actions for Dutch"]' do |menus|
      assert_equal ["Restore language"], JSON.parse(menus.sole["options"]).pluck("label")
    end
    approve
    assert_response :unprocessable_entity
    approve(@project.languages.find_by!(identifier: "en"))
    assert_response :unprocessable_entity
    assert_equal 0, CatalogReview.count
  end

  test "only people allowed to change project settings may approve in bulk" do
    %w[viewer translator].each do |role|
      @membership.update!(role: role)
      approve
      assert_response :forbidden
    end
    @membership.destroy!
    approve
    assert_response :forbidden
    assert_equal 0, CatalogReview.count
    @project.project_memberships.create!(user: @user, role: "owner")
    approve
    assert_response :success
  end

  test "approval rejects stale settings and unwritable catalogs without recording reviews" do
    old_revision = @project.revision
    CatalogWriter.new(@project).edit(expected: old_revision) { |w| w.add_key("new_key") }
    approve(revision: old_revision)
    assert_response :conflict
    @project.update!(sync_status: "running", sync_requested_at: Time.current)
    approve
    assert_response :unprocessable_entity
    @project.update!(sync_status: "failed", sync_error: "Malformed YAML")
    approve
    assert_response :unprocessable_entity
    assert_equal 0, CatalogReview.count
  end

  test "language identifiers cannot cross project boundaries" do
    other = Project.create!(name: "Other")
    other_language = other.languages.create!(identifier: "nl")
    approve(other_language)
    assert_response :not_found
    assert_equal 0, CatalogReview.count
  end

  test "bulk approval records pending text and source payloads without accepting drafts" do
    @project.update!(repository: "example/translations")
    state = CatalogState.new(@project)
    key = state.keys.find { |item| state.path(item) == "greeting" }
    writer = CatalogWriter.new(@project, actor: @user)
    writer.edit(expected: @project.reload.revision) { |w| w.translate(key.id, "nl", "Welkom %{name}") }
    writer.edit(expected: @project.reload.revision) { |w| w.translate(key.id, "en", "Welcome %{name}") }
    drafts = @project.catalog_drafts.map(&:attributes)
    approve
    assert_response :success
    state = CatalogState.new(@project, pending: true)
    text = state.translation(key.id, "nl")
    review = CatalogReview.find_by!(catalog_node_id: text.id)
    assert_equal text.payload.id, review.translation_payload_id
    assert_equal state.source_digest(key), review.source_digest
    assert_equal drafts, @project.catalog_drafts.reload.map(&:attributes)
    assert_equal "Hallo %{name}", CatalogState.new(@project).translation(key.id, "nl").payload.value
  end
end
