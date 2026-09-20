require "test_helper"

class ProjectSettingsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    @project = Project.create!(name: "Original", visibility: "public")
    @membership = @project.project_memberships.create!(user: @user, role: "admin")
    sign_in @user
  end

  test "admins rename while owners confirm visibility changes and URLs remain stable" do
    get settings_project_path(@project)
    assert_select "se-select[name='project[visibility]']", count: 0
    patch project_path(@project), params: { project: { name: "Renamed" } }
    assert_redirected_to settings_project_path(@project)
    assert_equal "Renamed", @project.reload.name
    assert_equal "original", @project.slug
    patch project_path(@project), params: { project: { visibility: "private" }, confirm_visibility: "1" }
    assert_response :forbidden
    assert_equal "public", @project.reload.visibility
    @membership.update!(role: "owner")
    patch project_path(@project), params: { project: { visibility: "private" } }
    assert_response :success
    assert_select "se-modal#project-visibility-confirmation[open]"
    assert_equal "public", @project.reload.visibility
    patch project_path(@project), params: { project: { visibility: "private" }, confirm_visibility: "1" }
    assert_redirected_to settings_project_path(@project)
    assert_equal "private", @project.reload.visibility
    patch project_path(@project), params: { project: { name: "", visibility: "invalid" } }
    assert_response :unprocessable_entity
    assert_equal "Renamed", @project.reload.name
  end

  test "project viewers translators and unrelated members cannot edit settings" do
    @user.update!(role: :member)
    %w[viewer translator].each do |role|
      @membership.update!(role: role)
      get settings_project_path(@project)
      assert_response :forbidden
      patch project_path(@project), params: { project: { name: "Forbidden" } }
      assert_response :forbidden
    end
    @membership.destroy!
    get settings_project_path(@project)
    assert_response :forbidden
    patch project_path(@project), params: { project: { visibility: "private" } }
    assert_response :forbidden
    assert_equal "Original", @project.reload.name
    assert_equal "public", @project.visibility
  end
  test "only owners change unique slugs after confirmation without preserving old URLs" do
    old_url = project_path(@project)
    patch old_url, params: { project: { slug: "new_slug" }, confirm_slug: "1" }
    assert_response :forbidden
    @membership.update!(role: "owner")
    Project.create!(name: "Taken", slug: "taken")
    patch old_url, params: { project: { slug: "taken" } }
    assert_response :unprocessable_entity
    assert_select "se-modal[open]", count: 0
    assert_select "se-input[name='project[slug]'][error]"
    assert_equal "original", @project.reload.slug
    patch old_url, params: { project: { slug: "new_slug" } }
    assert_response :success
    assert_select "se-modal[open] form[action=?]", old_url
    assert_select "input[name=confirm_slug][value='1']"
    assert_equal "original", @project.reload.slug
    # The chosen slug must still be free on the confirmation request.
    competitor = Project.create!(name: "New", slug: "new_slug")
    patch old_url, params: { project: { slug: "new_slug" }, confirm_slug: "1" }
    assert_response :unprocessable_entity
    competitor.destroy!
    patch old_url, params: { project: { slug: "new_slug" }, confirm_slug: "1" }
    assert_redirected_to settings_project_path("new_slug")
    assert_equal "new_slug", @project.reload.slug
    get old_url
    assert_response :not_found
    get project_sheets_path(@project)
    assert_response :success
  end

  test "last owner roles are locked in both project and global editors" do
    @membership.update!(role: "owner")
    get edit_project_project_membership_path(@project, @membership)
    assert_select "se-card se-select[name='project_membership[role]'][disabled]"
    assert_select "se-button[text='Remove member']", count: 0
    @user.update!(role: :owner)
    get edit_settings_user_path(@user)
    assert_select "se-select[name='user[role]'][disabled]"
    patch settings_user_path(@user), params: { user: { role: "guest" } }
    assert_response :unprocessable_entity
    assert @user.reload.owner?
  end

  test "table actions use accessible icon-only menus" do
    @user.update!(role: :owner)
    get settings_users_path
    assert_select "se-menu[icon-only][data-edit-url=?]", edit_settings_user_path(@user) do |menus|
      assert_equal [{ "id" => "edit", "label" => "Edit", "icon" => "pencil" }], JSON.parse(menus.first["options"])
    end
    assert_select ".app-user-identity .app-verification-status[aria-label]"
    get members_project_path(@project)
    assert_select "se-menu[icon-only][data-edit-url=?]", edit_project_project_membership_path(@project, @membership)
    get settings_project_path(@project)
    assert_select "se-collection[type=table] se-list-row", count: 3
    assert_select "form.app-setting-form", count: 3
  end

end
