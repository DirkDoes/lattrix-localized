require "test_helper"

class PolicyEnforcementTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    user = users(:one)
    user.update!(email_verified_at: Time.current)
    sign_in user
  end

  test "a resource action missing authorize is detected" do
    workspace = Workspace.create!(name: "Policy guard", visibility: "public")
    original = WorkspacesController.instance_method(:show)
    WorkspacesController.define_method(:show) { render plain: "Probe" }
    assert_raises(Pundit::AuthorizationNotPerformedError) { get workspace_path(workspace) }
  ensure
    WorkspacesController.define_method(:show, original) if original
  end

  test "a resource index missing policy scope is detected" do
    original = WorkspacesController.instance_method(:index)
    WorkspacesController.define_method(:index) do
      authorize Workspace
      render plain: "Probe"
    end
    assert_raises(Pundit::PolicyScopingNotPerformedError) { get workspaces_path }
  ensure
    WorkspacesController.define_method(:index, original) if original
  end
end
