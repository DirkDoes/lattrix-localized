require 'test_helper'

class CatalogPendingTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: 'Pending', repository: 'example/test')
    CatalogReconcile.new(@project, {'en' => "en:\n  name: Name\n"}, sha: 'first').apply!
    @writer = CatalogWriter.new(@project)
    @key = CatalogState.new(@project).keys.first
  end

  test 'descriptions save locally with history and no pending records' do
    @writer.edit(expected: @project.revision) { |w| w.change_key(@key.id, name: 'name', kind: 'scalar', description: 'Local help') }
    assert_equal 'Local help', CatalogState.new(@project).items[@key.id].payload.description
    assert_empty @project.catalog_drafts
    assert_empty CatalogPending.outgoing(@project)
    assert_equal 'payload_replaced', @project.catalog_events.reorder(id: :desc).first.action
  end

  test 'metadata alongside renames is saved without introducing sync conflicts' do
    @writer.edit(expected: @project.revision) { |w| w.change_key(@key.id, path: 'title', kind: 'scalar', description: 'Help') }
    assert_equal 'Help', CatalogState.new(@project).items[@key.id].payload.description
    assert_equal %w[name title], CatalogPending.outgoing(@project).map { |c| c[:path] }
    CatalogReconcile.new(@project, {'en' => "en:\n  name: Name\n"}, sha: 'second').apply!
    assert_not @project.catalog_drafts.any?(&:conflict?)
    CatalogReconcile.new(@project, {'en' => "en:\n  title: Name\n"}, sha: 'third').apply!
    assert_empty CatalogPending.outgoing(@project)
  end

  test 'diff excludes metadata but includes values moves and removals' do
    @writer.edit(expected: @project.revision) { |w| w.translate(@key.id, 'en', 'Updated') }
    assert_equal [{file: 'en.yml', path: 'name', before: 'Name', after: 'Updated'}], CatalogPending.outgoing(@project)
    assert_equal 'Name', CatalogState.new(@project).translation(@key.id, 'en').payload.value
  end

  test 'incoming file data ignores comments formatting and unsupported values' do
    before = CatalogPending.files({'en' => "en:\n  name: 'Name' # comment\n  number: 1\n"}, @project)
    after = CatalogPending.files({'en' => "---\nen:\n  number: 2\n  name: Name\n"}, @project)
    assert_empty CatalogPending.diff(before, after)
  end

  test 'new empty languages still represent outgoing GitHub files' do
    @project.languages.create!(identifier: 'fr', pending_repository: true)
    assert_equal [{file: 'fr.yml', path: 'New language file', before: nil, after: 'fr: {}'}], CatalogPending.outgoing(@project)
  end
end
