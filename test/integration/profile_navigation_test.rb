require "test_helper"

class ProfileNavigationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "workspace invitations never select personal invitations" do
    user = users(:one)
    user.update!(email_verified_at: Time.current)
    workspace = Workspace.create!(name: "Team")
    workspace.workspace_memberships.create!(user: user, role: "owner")
    sign_in user
    get workspace_workspace_invites_path(workspace)
    assert_response :success
    assert_select "se-sidebar-button[href=?][active]", workspace_path(workspace)
    assert_select "se-sidebar-button[href=?][active]", workspace_invites_path, count: 0
    get workspace_invites_path
    assert_select "se-sidebar-button[href=?][active]", workspace_invites_path
  end

  test "initials discard punctuation and symbol only words on every profile" do
    helper = ApplicationController.helpers
    assert_equal "AB", helper.profile_initials("_|+~! / [] =:; ><?@#$%^&*()- Alice #Bob")
    assert_equal "É李", helper.profile_initials("!!Élodie ~ 李")
    assert_equal "A", helper.profile_initials("__Alice__")
    assert_equal "", helper.profile_initials("_|+~![]")
    user = users(:one)
    user.update!(name: "__Alice #Bob", email_verified_at: Time.current)
    sign_in user
    get edit_settings_user_path(user)
    assert_select "se-topbar se-profile[initials=AB]"
    assert_select "se-card se-profile[initials=AB]"
    workspace = Workspace.create!(name: "Team")
    workspace.workspace_memberships.create!(user: user, role: "owner")
    get members_workspace_path(workspace)
    assert_select "se-list-row se-profile[initials=AB]"
  end
end
