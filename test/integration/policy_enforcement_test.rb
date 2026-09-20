require "test_helper"

class PolicyEnforcementTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    user = users(:one)
    user.update!(email_verified_at: Time.current)
    sign_in user
  end

  test "a resource action missing authorize is detected" do
    project = Project.create!(name: "Policy guard", visibility: "public")
    original = ProjectsController.instance_method(:show)
    ProjectsController.define_method(:show) { render plain: "Probe" }
    assert_raises(Pundit::AuthorizationNotPerformedError) { get project_path(project) }
  ensure
    ProjectsController.define_method(:show, original) if original
  end

  test "a resource index missing policy scope is detected" do
    original = ProjectsController.instance_method(:index)
    ProjectsController.define_method(:index) do
      authorize Project
      render plain: "Probe"
    end
    assert_raises(Pundit::PolicyScopingNotPerformedError) { get projects_path }
  ensure
    ProjectsController.define_method(:index, original) if original
  end
end
