require "test_helper"
require "minitest/mock"

class CatalogOptionsTest < ActiveSupport::TestCase
  setup { @project = Project.create!(name: "Options") }

  test "new defaults and owner ceilings retain application owner overrides" do
    assert_equal [100, 3, 15, 'simple'], [@project.max_locale_files, @project.max_locale_file_mb, @project.max_locale_total_mb, @project.pluralization_mode]
    @project.max_locale_files = 501
    assert_not @project.valid?
    @project.settings_actor = users(:one)
    @project.settings_actor.update!(role: :owner)
    @project.save!
    @project = Project.find(@project.id)
    @project.update!(name: 'Still valid')
    assert_equal 501, @project.max_locale_files
    @project.max_locale_files = 502
    assert_not @project.valid?
    @project.max_locale_files = 500
    assert @project.valid?
  end

  test "parser uses project count per file and combined limits" do
    @project.update!(max_locale_files: 1, max_locale_file_mb: 1, max_locale_total_mb: 1)
    assert_raises(ArgumentError) { CatalogYaml.new({'en'=>'en: {}', 'nl'=>'nl: {}'}, @project) }
    assert_raises(ArgumentError) { CatalogYaml.new({'en'=>"en:\n  a: #{'a' * 1.megabyte}"}, @project) }
    @project.update!(max_locale_files: 2)
    assert_raises(ArgumentError) { CatalogYaml.new({'en'=>"en:\n  a: #{'a' * 600_000}", 'nl'=>"nl:\n  a: #{'a' * 600_000}"}, @project) }
    assert CatalogYaml.new({'en'=>'en: {}'}, @project)
  end

  test "simple and cldr categories differ and off does not enforce count" do
    assert_equal %w[one other], @project.plural_categories('ar')
    @project.update!(pluralization_mode: 'cldr')
    assert_equal %w[zero one two few many other].sort, @project.plural_categories('ar').sort
    @project.update!(pluralization_mode: 'off')
    assert_empty @project.plural_categories('ar')
    CatalogReconcile.new(@project, {'en'=>"en:\n  things:\n    other: '%{count} things'\n"}, sha: 'off').apply!
    state = CatalogState.new(@project)
    assert_equal 'branch', state.keys.find { |key| key.payload.name == 'things' }.payload.kind
    assert_empty state.invalid_groups
  end

  def preview(files)
    Project.transaction(requires_new: true) do
      CatalogReconcile.new(@project, files, sha: 'preview', pr_check: true).apply!
      raise ActiveRecord::Rollback
    end
  end

  test "PR switches do not weaken normal reconciliation or persist previews" do
    files = {'en'=>"en:\n  greeting: 'Hello %{name}'\n", 'nl'=>"nl:\n  greeting: Hallo\n"}
    assert_raises(ArgumentError) { preview(files) }
    @project.reload.update!(pr_validation_checks: {'scalar_placeholders'=>false})
    preview(files)
    assert_empty @project.catalog_nodes.reload
    assert_raises(ArgumentError) { CatalogReconcile.new(@project, files, sha: 'live').apply! }
  end

  test "plural completeness and count checks can be independently disabled for PRs" do
    files = {'en'=>"en:\n  things:\n    other: Things\n"}
    assert_raises(ArgumentError) { preview(files) }
    @project.reload.update!(pr_validation_checks: {'plural_completeness'=>false})
    assert_raises(ArgumentError) { preview(files) }
    @project.reload.update!(pr_validation_checks: {'plural_completeness'=>false, 'count_placeholders'=>false})
    preview(files)
    assert_empty @project.catalog_nodes.reload
  end

  test "source key check can be disabled but malformed YAML cannot" do
    files = {'en'=>"en: {}\n", 'nl'=>"nl:\n  extra: Extra\n"}
    assert_raises(ArgumentError) { preview(files) }
    @project.reload.update!(pr_validation_checks: {'source_keys'=>false})
    preview(files)
    assert_raises(ArgumentError) { preview({'en'=>'en: [broken'}) }
  end

  test "disabled validation reports neutral without fetching files" do
    @project.update!(repository: 'org/repo', git_branch: 'main', installation_id: 1, pr_validation_enabled: false)
    api = Minitest::Mock.new
    api.expect(:repo_path, '/repos/org/repo')
    api.expect(:request, {'base'=>{'ref'=>'main'}, 'head'=>{'sha'=>'head'}}, [:get, '/repos/org/repo/pulls/1'])
    api.expect(:repo_path, '/repos/org/repo')
    api.expect(:request, {}) { |method, path, data| method == :post && path.end_with?('/check-runs') && data[:conclusion] == 'neutral' }
    CatalogGithub.stub(:new, api) { CatalogCheckJob.perform_now(@project.id, 1) }
    assert api.verify
  end

  test "PR checks pin the head SHA report progress and leave no imported records" do
    @project.update!(repository: 'org/repo', git_branch: 'main', installation_id: 1)
    api = Object.new
    calls = []
    api.define_singleton_method(:repo_path) { '/repos/org/repo' }
    api.define_singleton_method(:request) do |method, path, data = nil|
      calls << [method, path, data]
      path.end_with?('/pulls/1') ? {'base'=>{'ref'=>'main'}, 'head'=>{'sha'=>'pinned'}} : {'id'=>42}
    end
    api.define_singleton_method(:snapshot) do |sha|
      raise 'Wrong snapshot' unless sha == 'pinned'
      [{'sha'=>sha}, {'en'=>"en:\n  hello: Hello\n"}]
    end
    CatalogGithub.stub(:new, api) { CatalogCheckJob.perform_now(@project.id, 1) }
    assert_equal 'in_progress', calls[1].last[:status]
    assert_equal [:patch, '/repos/org/repo/check-runs/42'], calls.last.first(2)
    assert_equal 'success', calls.last.last[:conclusion]
    assert_empty @project.reload.catalog_nodes
    assert_empty @project.catalog_change_sets
  end

  test "sync with publication enabled does not publish without local changes" do
    @project.update!(repository: 'org/repo', installation_id: 1, git_branch: 'main')
    api = Object.new
    api.define_singleton_method(:snapshot) { [{'sha'=>'base'}, {'en'=>"en:\n  hello: Hello\n"}] }
    # No publish! method: publishing unnecessarily would fail the test.
    CatalogGithub.stub(:new, api) { CatalogSyncJob.perform_now(@project.id, publish: true) }
    assert_equal 'succeeded', @project.reload.sync_status
    assert_nil @project.pull_request_number
    assert_match(/No publishable pending changes/, @project.sync_message)
  end
end
