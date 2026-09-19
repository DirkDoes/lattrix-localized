require "test_helper"

class WorkspaceSettingsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    @workspace = Workspace.create!(name: "Original", visibility: "public")
    @membership = @workspace.workspace_memberships.create!(user: @user, role: "admin")
    sign_in @user
  end

  test "admins rename while owners confirm visibility changes and URLs remain stable" do
    get settings_workspace_path(@workspace)
    assert_select "se-select[name='workspace[visibility]']", count: 0
    patch workspace_path(@workspace), params: { workspace: { name: "Renamed" } }
    assert_redirected_to settings_workspace_path(@workspace)
    assert_equal "Renamed", @workspace.reload.name
    assert_equal "original", @workspace.slug
    patch workspace_path(@workspace), params: { workspace: { visibility: "private" }, confirm_visibility: "1" }
    assert_response :forbidden
    assert_equal "public", @workspace.reload.visibility
    @membership.update!(role: "owner")
    patch workspace_path(@workspace), params: { workspace: { visibility: "private" } }
    assert_response :success
    assert_select "se-modal#workspace-visibility-confirmation[open]"
    assert_equal "public", @workspace.reload.visibility
    patch workspace_path(@workspace), params: { workspace: { visibility: "private" }, confirm_visibility: "1" }
    assert_redirected_to settings_workspace_path(@workspace)
    assert_equal "private", @workspace.reload.visibility
    patch workspace_path(@workspace), params: { workspace: { name: "", visibility: "invalid" } }
    assert_response :unprocessable_entity
    assert_equal "Renamed", @workspace.reload.name
  end

  test "workspace viewers translators and unrelated members cannot edit settings" do
    @user.update!(role: :member)
    %w[viewer translator].each do |role|
      @membership.update!(role: role)
      get settings_workspace_path(@workspace)
      assert_response :forbidden
      patch workspace_path(@workspace), params: { workspace: { name: "Forbidden" } }
      assert_response :forbidden
    end
    @membership.destroy!
    get settings_workspace_path(@workspace)
    assert_response :forbidden
    patch workspace_path(@workspace), params: { workspace: { visibility: "private" } }
    assert_response :forbidden
    assert_equal "Original", @workspace.reload.name
    assert_equal "public", @workspace.visibility
  end
  test "only owners change unique slugs after confirmation without preserving old URLs" do
    old_url = workspace_path(@workspace)
    patch old_url, params: { workspace: { slug: "new_slug" }, confirm_slug: "1" }
    assert_response :forbidden
    @membership.update!(role: "owner")
    Workspace.create!(name: "Taken", slug: "taken")
    patch old_url, params: { workspace: { slug: "taken" } }
    assert_response :unprocessable_entity
    assert_select "se-modal[open]", count: 0
    assert_select "se-input[name='workspace[slug]'][error]"
    assert_equal "original", @workspace.reload.slug
    patch old_url, params: { workspace: { slug: "new_slug" } }
    assert_response :success
    assert_select "se-modal[open] form[action=?]", old_url
    assert_select "input[name=confirm_slug][value='1']"
    assert_equal "original", @workspace.reload.slug
    # The chosen slug must still be free on the confirmation request.
    competitor = Workspace.create!(name: "New", slug: "new_slug")
    patch old_url, params: { workspace: { slug: "new_slug" }, confirm_slug: "1" }
    assert_response :unprocessable_entity
    competitor.destroy!
    patch old_url, params: { workspace: { slug: "new_slug" }, confirm_slug: "1" }
    assert_redirected_to settings_workspace_path("new_slug")
    assert_equal "new_slug", @workspace.reload.slug
    get old_url
    assert_response :not_found
    get workspace_path(@workspace)
    assert_response :success
  end

  test "last owner roles are locked in both workspace and global editors" do
    @membership.update!(role: "owner")
    get edit_workspace_workspace_membership_path(@workspace, @membership)
    assert_select "se-card se-select[name='workspace_membership[role]'][disabled]"
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
    get members_workspace_path(@workspace)
    assert_select "se-menu[icon-only][data-edit-url=?]", edit_workspace_workspace_membership_path(@workspace, @membership)
    get settings_workspace_path(@workspace)
    assert_select "se-collection[type=table] se-list-row", count: 3
    assert_select "form.app-setting-form", count: 3
  end

end
