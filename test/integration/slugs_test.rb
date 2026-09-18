require "test_helper"

class SlugsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "slugs are normalized, stable, unique within the correct scope and used by routes" do
    owner = users(:one)
    owner.update!(email_verified_at: Time.current, role: :admin)
    sign_in owner
    post workspaces_path, params: { workspace: { name: "Acme", slug: " ACME-Team " } }
    workspace = Workspace.find_by!(slug: "acme-team")
    assert_redirected_to "/workspaces/acme-team"
    workspace.update!(name: "Renamed")
    assert_equal "acme-team", workspace.slug
    duplicate = Workspace.new(name: "Other", slug: "acme-team")
    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:slug, :taken)
    other = Workspace.create!(name: "Acme Team")
    assert_equal "acme-team-2", other.slug
    other.workspace_memberships.create!(user: owner, role: "owner")
    post workspace_projects_path(workspace), params: { project: { name: "Website", slug: "website" } }
    assert_redirected_to "/workspaces/acme-team/projects/website"
    project = workspace.projects.sole
    assert_not workspace.projects.new(name: "Duplicate", slug: "website").valid?
    assert other.projects.create!(name: "Website", slug: "website")
    get translations_workspace_project_path(workspace, project)
    assert_response :success
    assert_equal "/workspaces/acme-team/projects/website/translations", request.path
    %w[new edit with_underscore].each do |slug|
      assert_not Workspace.new(name: "Name", slug: slug).valid?
    end
    assert_raises ActiveRecord::RecordNotUnique do
      Workspace.transaction(requires_new: true) { other.update_columns(slug: workspace.slug) }
    end
    snake = workspace.projects.create!(name: "My New Project", slug: "my_new_project")
    assert_equal "my_new_project", snake.reload.slug
    get workspace_project_path(workspace, snake)
    assert_response :success
    automatic = workspace.projects.create!(name: "Another New Project")
    assert_equal "another_new_project", automatic.slug
    sibling = workspace.projects.create!(name: "Sibling")
    assert_raises ActiveRecord::RecordNotUnique do
      Project.transaction(requires_new: true) { sibling.update_columns(slug: project.slug) }
    end
  end
end
