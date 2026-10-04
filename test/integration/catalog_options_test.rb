require "test_helper"
class CatalogOptionsFlowTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  setup do
    @user = users(:one)
    @user.update!(role: :member, email_verified_at: Time.current)
    @project = Project.create!(name: 'Options UI')
    @membership = @project.project_memberships.create!(user: @user, role: 'owner')
    sign_in @user
  end
  test "only project owners or application owners may edit limits" do
    patch project_path(@project), params: {project: {max_locale_files: 500, max_locale_file_mb: 5, max_locale_total_mb: 30}}
    assert_response :redirect
    assert_equal 500, @project.reload.max_locale_files
    patch project_path(@project), params: {project: {max_locale_files: 501}}
    assert_response :unprocessable_entity
    assert_equal 500, @project.reload.max_locale_files
    @project.project_memberships.create!(user: users(:two), role: 'owner')
    @membership.update!(role: 'admin')
    patch project_path(@project), params: {project: {max_locale_files: 400}}
    assert_response :forbidden
    assert_equal 500, @project.reload.max_locale_files
    @user.update!(role: :owner)
    patch project_path(@project), params: {project: {max_locale_files: 750}}
    assert_response :redirect
    assert_equal 750, @project.reload.max_locale_files
  end
  test "disabled validation retains individual choices and off hides plural checks" do
    patch project_path(@project), params: {project: {pr_validation_checks: {scalar_placeholders: '0'}}}
    assert_response :redirect
    patch project_path(@project), params: {project: {pr_validation_enabled: '0', pluralization_mode: 'off'}}
    assert_response :redirect
    assert_not @project.reload.pr_check?(:scalar_placeholders)
    get settings_project_path(@project)
    assert_select '[data-validation-options][hidden]'
    assert_select '[data-plural-check][hidden]', count: 2
    patch project_path(@project), params: {project: {pr_validation_enabled: '1'}}
    assert @project.reload.pr_validation_enabled?
    assert_not @project.pr_check?(:scalar_placeholders)
  end

  test "changing plural modes preserves translations and adds required categories" do
    @project.languages.create!(identifier: 'ar')
    writer = CatalogWriter.new(@project)
    writer.edit(expected: @project.revision) { |edit| edit.add_key('things', kind: 'plural') }
    state = CatalogState.new(@project, pending: true)
    other = state.keys.find { |key| key.payload.name == 'other' }
    writer.edit(expected: @project.revision) { |edit| edit.translate(other.id, 'en', '%{count} things') }
    patch project_path(@project), params: {project: {pluralization_mode: 'off'}}
    assert_response :redirect
    state = CatalogState.new(@project.reload, pending: true)
    assert_nil state.plural_parent(state.items.fetch(other.id))
    assert_equal '%{count} things', state.translation(other.id, 'en').payload.value
    get translations_project_path(@project)
    assert_select 'se-input[data-completion-plural="true"][aria-label="things.other — English"]'
    patch project_path(@project), params: {project: {pluralization_mode: 'cldr'}}
    assert_response :redirect
    state = CatalogState.new(@project.reload, pending: true)
    assert state.plural_parent(state.items.fetch(other.id))
    assert_includes state.keys.map { |key| key.payload.name }, 'few'
    assert_equal '%{count} things', state.translation(other.id, 'en').payload.value
  end
end
