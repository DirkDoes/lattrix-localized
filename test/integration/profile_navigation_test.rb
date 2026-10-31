require "test_helper"

class ProfileNavigationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "workspace shell separates project navigation and settings sections from scrolling content" do
    user = users(:one)
    user.update!(email_verified_at: Time.current)
    project = Project.create!(name: "Layout project")
    project.project_memberships.create!(user: user, role: "owner")
    sign_in user

    get translations_project_path(project)
    assert_select "header.app-topbar se-profile", count: 1
    assert_select "header.app-topbar #app-project-heading se-title", text: project.name
    assert_select "template[data-project-heading] se-title", text: project.name
    assert_select ".app-project-bar se-title", count: 0
    assert_select "aside.app-navigation se-profile", count: 0
    assert_select "turbo-frame#app-content > header.app-project-bar se-nav-tabs", count: 1
    assert_select "main se-nav-tabs[label='Project navigation']", count: 0
    assert_select ".app-settings-navigation", count: 0

    get settings_project_path(project)
    assert_select ".app-project-bar se-nav-tabs[value=settings]"
    assert_select ".app-settings-navigation [href='#project-languages']"
    assert_select "main #project-languages"
    assert_select "main #project-repository"

    get edit_settings_user_path(user)
    assert_select "#app-project-heading se-title, template[data-project-heading] se-title", count: 0
    assert_select ".app-project-bar", count: 0
    assert_select ".app-settings-navigation [href='#account-security']"
    assert_select "main #account-security"

    get projects_path
    assert_select "#app-project-heading se-title", count: 0
    assert_select ".app-project-bar, .app-settings-navigation", count: 0
  end

  test "public project readers have the project strip and login without workspace panels" do
    project = Project.create!(name: "Public layout", visibility: "public")
    get translations_project_path(project)
    assert_response :success
    assert_select "header.app-topbar se-button[href=?]", new_user_session_path
    assert_select ".app-project-bar se-nav-tabs", count: 1
    assert_select "aside.app-navigation, .app-settings-navigation, se-panel-toggle", count: 0
  end

  test "project invitations never select personal invitations" do
    user = users(:one)
    user.update!(email_verified_at: Time.current)
    project = Project.create!(name: "Team")
    project.project_memberships.create!(user: user, role: "owner")
    sign_in user
    get project_project_invites_path(project)
    assert_response :success
    assert_select "se-nav-item[href=?][active]", project_path(project)
    assert_select "se-nav-item[href=?][active]", project_invites_path, count: 0
    get project_invites_path
    assert_select "se-nav-item[href=?][active]", project_invites_path
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
    assert_select "header.app-topbar se-profile[initials=AB]"
    assert_select "se-card se-profile[initials=AB]"
    project = Project.create!(name: "Team")
    project.project_memberships.create!(user: user, role: "owner")
    get members_project_path(project)
    assert_select "se-list-row se-profile[initials=AB]"
  end
end
