require "test_helper"

class SheetsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "sidebar collapse preference survives navigation" do
    owner = users(:one)
    owner.update!(email_verified_at: Time.current, role: :member)
    sign_in owner
    cookies[:sidebar_collapsed] = "true"
    get projects_path
    assert_select "se-sidebar[collapsed]:not([collapsible])"
    get projects_path
    assert_select "se-sidebar[collapsed]:not([collapsible])"
    cookies[:sidebar_collapsed] = "false"
    get projects_path
    assert_select "se-sidebar:not([collapsible]):not([collapsed])"
  end

  test "sheets stay scoped, creation is authorized, and navigation follows the scope" do
    owner = users(:one)
    owner.update!(email_verified_at: Time.current, role: :member)
    project = Project.create!(name: "Team", visibility: "private")
    membership = project.project_memberships.create!(user: owner, role: "owner")
    project.project_memberships.create!(user: users(:two), role: "owner")
    sign_in owner
    get project_sheets_path(project)
    assert_select "header se-button[data-open-modal=sheet-create-modal]", count: 0
    assert_select "se-empty-illustration[variant=folders][title='No sheets yet'] se-button[data-open-modal=sheet-create-modal]", count: 1
    membership.update!(role: "viewer")
    get project_sheets_path(project)
    assert_select "se-empty-illustration[variant=folders]"
    assert_select "se-button[data-open-modal=sheet-create-modal]", count: 0
    membership.update!(role: "owner")
    post project_sheets_path(project), params: { sheet: { name: "Website", visibility: "public" } }
    sheet = project.sheets.sole
    assert_redirected_to project_sheet_path(project, sheet)
    assert_equal "private", sheet.effective_visibility
    get translations_project_sheet_path(project, sheet)
    assert_select "se-sidebar:not([collapsible]):not([variant])", count: 1
    assert_select "se-nav-tabs[label='Sheet navigation']"
    assert_select "se-sidebar-button[label=Translations]", count: 0
    assert_select "se-sidebar se-sidebar-chapter:not([layout-mode]) se-sidebar-group[variant=page]"
    assert_select "se-topbar se-profile"
    assert_select "se-topbar se-layout-brand"
    assert_select "se-sidebar se-layout-brand[collapsible]"
    assert_select "se-topbar se-layout-brand[collapsible]", count: 0
    assert_select "se-topbar[layout-mode=mobile-only]"
    assert_select "se-sidebar > header[layout-mode=desktop-only] se-layout-brand"
    assert_select "se-sidebar > footer[layout-mode=desktop-only] se-profile[data-profile-menu]"
    assert_select "se-breadcrumbs", count: 0
    assert_select "se-sidebar-chapter[title=Project]"
    assert_select "dialog#app-navigation", count: 0
    get translations_project_sheet_path(project, sheet)
    assert_response :success
    get project_sheets_path(project)
    assert_select "se-nav-tabs[value=sheets]"
    assert_select "se-project-card[title=Website]"
    assert_select "header se-button[data-open-modal=sheet-create-modal]", count: 1
    assert_select ".app-page > se-empty-illustration", count: 0
    assert_select "se-sidebar:not([collapsible]):not([variant])", count: 1
    assert_select "se-breadcrumbs", count: 0
    assert_select ".app-mobile-projects", count: 0
    get projects_path
    assert_select "se-sidebar-group[variant=page][active]"
    assert_no_difference "Sheet.count" do
      post project_sheets_path(project), params: { sheet: { name: "", visibility: "bad" } }
    end
    assert_response :unprocessable_entity
    assert_select "se-modal#sheet-create-modal[open]"
    membership.update!(role: "viewer")
    post project_sheets_path(project), params: { sheet: { name: "Forbidden" } }
    assert_response :forbidden
    other = Project.create!(name: "Other")
    other.project_memberships.create!(user: owner, role: "owner")
    get translations_project_sheet_path(other, sheet)
    assert_response :not_found
    membership.destroy!
    get project_sheets_path(project)
    assert_response :not_found
  end
end
