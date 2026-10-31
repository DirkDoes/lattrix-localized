require "test_helper"
require "minitest/mock"

class CatalogLoadingTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  setup do
    @user = users(:one)
    @user.update!(role: :member, email_verified_at: Time.current)
    @project = Project.create!(name: "Loading", visibility: "public")
    @membership = @project.project_memberships.create!(user: @user, role: "admin")
    CatalogReconcile.new(@project, {
      "en" => "en:\n  name: Name\n", "nl" => "nl:\n  name: Naam\n", "fr" => "fr:\n  name: Bonjour\n"
    }, sha: "initial").apply!
    @key = CatalogState.new(@project).keys.sole
    sign_in @user
  end
  def read(**params)
    get translations_project_path(@project), params: {locale: "nl", **params}, as: :json
  end
  test "switching existing rows sends target cells without source cells or hidden editors" do
    get translations_project_path(@project), params: {locale: "nl"}
    assert_select "#catalog-modals se-modal", count: 0
    assert_select '[data-catalog-language-status][hidden] se-spinner'
    read(known: @key.id.to_s)
    assert_response :success
    rows = Nokogiri::HTML.fragment(response.parsed_body["rows"])
    assert_equal [@key.id.to_s], rows.css("[data-catalog-key]").map { |node| node["data-catalog-key"] }
    assert_equal 1, rows.css("[data-catalog-target]").size
    assert_equal 1, rows.css(".catalog-value").size
    assert_empty rows.css(".catalog-key, se-modal")
    assert_includes response.parsed_body["rows"], "Naam"
    assert_not response.parsed_body.key?("modals")
    assert_match(/catalog;dur=/, response.headers["Server-Timing"])
    assert_match(/projection;dur=/, response.headers["Server-Timing"])
  end
  test "unchanged snapshots revalidate without loading a catalog projection" do
    read
    etag = response.headers["ETag"]
    assert_match(/private/, response.headers["Cache-Control"])
    CatalogState.stub(:new, ->(*) { flunk "A cache hit must not rebuild the catalog" }) do
      get translations_project_path(@project), params: {locale: "nl"}, headers: {"Accept" => "application/json", "If-None-Match" => etag}
      assert_response :not_modified
      assert_empty response.body
    end
  end
  test "review approvals invalidate snapshots without a catalog revision change" do
    read
    etag = response.headers["ETag"]
    revision = @project.reload.revision
    state = CatalogState.new(@project)
    text = state.translation(@key.id, "nl")
    CatalogReview.create!(catalog_node_id: text.id, actor: @user, source_digest: state.source_digest(@key), translation_payload_id: text.payload.id)
    get translations_project_path(@project), params: {locale: "nl"}, headers: {"Accept" => "application/json", "If-None-Match" => etag}
    assert_response :success
    assert_not_equal etag, response.headers["ETag"]
    assert_equal revision, @project.reload.revision
    assert_not_includes response.parsed_body["rows"], "Needs review"
  end
  test "permission changes invalidate snapshots and cannot reuse editable pending content" do
    @project.update!(repository: "example/translations")
    CatalogWriter.new(@project).edit(expected: @project.revision) { |w| w.translate(@key.id, "nl", "Pending secret") }
    read
    etag = response.headers["ETag"]
    assert_includes response.parsed_body["rows"], "Pending secret"
    @membership.destroy!
    get translations_project_path(@project), params: {locale: "nl"}, headers: {"Accept" => "application/json", "If-None-Match" => etag}
    assert_response :success
    assert_not_equal etag, response.headers["ETag"]
    assert_not_includes response.parsed_body["rows"], "Pending secret"
    assert_not_includes response.parsed_body["rows"], 'data-controller="catalog-cell"'
  end
  test "assignment changes invalidate translator editing permissions" do
    @membership.update!(role: "translator")
    @membership.languages << @project.languages.find_by!(identifier: "nl")
    read
    etag = response.headers["ETag"]
    @membership.membership_languages.destroy_all
    get translations_project_path(@project), params: {locale: "nl"}, headers: {"Accept" => "application/json", "If-None-Match" => etag}
    assert_response :success
    assert_not_equal etag, response.headers["ETag"]
    assert_not_includes response.parsed_body["rows"], 'data-controller="catalog-cell"'
  end
  test "on demand editors retain current values and enforce project and language permissions" do
    get editor_project_path(@project), params: {kind: "text", node_id: @key.id, locale: "nl"}
    assert_response :success
    assert_select 'se-input[name=value][value=Naam]'
    assert_equal "no-store", response.headers["Cache-Control"]
    @membership.update!(role: "translator")
    get editor_project_path(@project), params: {kind: "key", node_id: @key.id}
    assert_response :forbidden
    get editor_project_path(@project), params: {kind: "text", node_id: @key.id, locale: "nl"}
    assert_response :forbidden
    @membership.languages << @project.languages.find_by!(identifier: "nl")
    get editor_project_path(@project), params: {kind: "text", node_id: @key.id, locale: "nl"}
    assert_response :success
    other = Project.create!(name: "Other")
    CatalogWriter.new(other).edit(expected: other.revision) { |w| w.add_key("private_key") }
    get editor_project_path(@project), params: {kind: "text", node_id: CatalogState.new(other).keys.sole.id, locale: "nl"}
    assert_response :not_found
  end
  test "display projections narrow languages while cross language searches still work" do
    state = CatalogState.new(@project, pending: true, locales: %w[en nl])
    assert_equal %w[en nl], state.texts.map { |text| text.payload.locale }.sort
    assert_equal [@key.id], state.keys.map(&:id)
    read(q: "Bonjour")
    assert_includes response.parsed_body["rows"], 'data-catalog-key'
  end
  test "prefetch JSON returns one batch rather than all preceding pages" do
    CatalogWriter.new(@project).edit(expected: @project.revision) { |w| 85.times { |i| w.add_key("key_#{i}") } }
    read(page: 2, batch: "1")
    rows = Nokogiri::HTML.fragment(response.parsed_body["rows"])
    assert_equal 40, rows.css("[data-catalog-key]").size
    assert_empty rows.css("se-modal")
    assert_includes response.parsed_body["more"], "page=3"
  end
end
