require "test_helper"

class SlugsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "slugs are normalized, stable, unique within the correct scope and used by routes" do
    owner = users(:one)
    owner.update!(email_verified_at: Time.current, role: :admin)
    sign_in owner
    post projects_path, params: { project: { name: "Acme", slug: " ACME-Team " } }
    project = Project.find_by!(slug: "acme-team")
    assert_redirected_to "/projects/acme-team"
    project.update!(name: "Renamed")
    assert_equal "acme-team", project.slug
    duplicate = Project.new(name: "Other", slug: "acme-team")
    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:slug, :taken)
    other = Project.create!(name: "Acme Team")
    assert_equal "acme_team", other.slug
    assert_equal "acme_team-2", Project.create!(name: "Acme Team").slug
    other.project_memberships.create!(user: owner, role: "owner")
    post project_sheets_path(project), params: { sheet: { name: "Website", slug: "website" } }
    assert_redirected_to "/projects/acme-team/sheets/website"
    sheet = project.sheets.sole
    assert_not project.sheets.new(name: "Duplicate", slug: "website").valid?
    assert other.sheets.create!(name: "Website", slug: "website")
    get translations_project_sheet_path(project, sheet)
    assert_response :success
    assert_equal "/projects/acme-team/sheets/website/translations", request.path
    %w[new edit double__underscore].each do |slug|
      assert_not Project.new(name: "Name", slug: slug).valid?
    end
    assert_raises ActiveRecord::RecordNotUnique do
      Project.transaction(requires_new: true) { other.update_columns(slug: project.slug) }
    end
    snake = project.sheets.create!(name: "My New Sheet", slug: "my_new_sheet")
    assert_equal "my_new_sheet", snake.reload.slug
    get translations_project_sheet_path(project, snake)
    assert_response :success
    automatic = project.sheets.create!(name: "Another New Sheet")
    assert_equal "another_new_sheet", automatic.slug
    sibling = project.sheets.create!(name: "Sibling")
    assert_raises ActiveRecord::RecordNotUnique do
      Sheet.transaction(requires_new: true) { sibling.update_columns(slug: sheet.slug) }
    end
  end
end
