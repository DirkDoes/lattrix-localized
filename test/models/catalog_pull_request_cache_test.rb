require 'test_helper'
require 'minitest/mock'

class CatalogPullRequestCacheTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: 'PR cache', repository: 'org/repo', git_branch: 'main')
    @cache = CatalogPullRequestCache.for(@project)
    @cache.update!(connection: @cache.connection_key, refresh_token: 'test', requested_at: Time.current)
  end

  test 'changed malformed YAML rejects the preview and unrelated invalid files do not block valid diffs' do
    before = {'en'=>"en:\n  label: Before\n", 'devise.en'=>"en: broken: yaml"}
    after = before.merge('en'=>"en:\n  label: After\n")
    changes = CatalogPending.file_diff(before, after, @project)
    assert_equal 1, changes.size
    assert_equal 'After', changes.first[:after]
    after['en'] = "en:\n  label: After: broken\n"
    assert_raises(ArgumentError) { CatalogPending.file_diff(before, after, @project) }
  end

  test 'fresh snapshots do not enqueue refresh on every visit and reconnects hide old PRs' do
    @cache.update!(refresh_token: nil, fetched_at: Time.current, pulls: [{'number'=>1}])
    CatalogPullRequestRefreshJob.stub(:perform_later, ->(*) { raise 'Unexpected refresh' }) { @cache.refresh_later }
    assert_equal 1, @cache.current_pulls.size
    @project.update!(repository: 'other/repo')
    assert_empty @cache.reload.current_pulls
  end

  test 'refresh drops closed PRs reuses unchanged diffs and includes outgoing PR metadata' do
    @cache.update!(pulls: [{'number'=>1, 'identity'=>%w[base head], 'changes'=>[{'path'=>'label', 'after'=>'Value'}]}, {'number'=>2}])
    api = Object.new
    api.define_singleton_method(:incoming) do |_page, include_outgoing:|
      raise 'Must include outgoing PR' unless include_outgoing
      [[{'number'=>1, 'title'=>'Open PR', 'base'=>{'sha'=>'base'}, 'head'=>{'sha'=>'head'}}], false]
    end
    CatalogGithub.stub(:new, api) { CatalogPullRequestRefreshJob.perform_now(@project.id, 'test') }
    assert_equal [1], @cache.reload.pulls.map { |pull| pull['number'] }
    assert_equal 'Value', @cache.pulls.first['changes'].first['after']
    assert_not @cache.refreshing?
  end

  test 'superseded workers cannot resurrect closed PRs or write old repository results' do
    api = Object.new
    cache = @cache
    api.define_singleton_method(:incoming) do |_page, include_outgoing:|
      cache.update!(refresh_token: 'new', pulls: [])
      [[], false]
    end
    CatalogGithub.stub(:new, api) { CatalogPullRequestRefreshJob.perform_now(@project.id, 'test') }
    assert_equal 'new', @cache.reload.refresh_token
    assert_nil @cache.fetched_at
  end
end
