require "test_helper"
class TranslationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  def race(&operation)
    ready=Queue.new; start=Queue.new
    workers=2.times.map do
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ready << true; start.pop
          begin
            operation.call
            :saved
          rescue ActiveRecord::StatementInvalid, ActiveRecord::StaleObjectError
            :rejected
          end
        end
      end
    end
    2.times { ready.pop }; 2.times { start << true }
    workers.map(&:value).sort
  ensure
    workers&.each(&:join)
  end
  test "simultaneous key creates and stale edits cannot overwrite each other" do
    project=Project.create!(name:"Concurrent translations #{SecureRandom.hex(4)}")
    language=project.languages.create!(name:"English",identifier:"en",enabled:true)
    sheet=project.sheets.create!(name:"Sheet",default_language:language)
    tree=sheet.translation_tree
    assert_equal [:rejected,:saved],race { Recording.create_key!(tree:TranslationTree.find(tree.id),parent:nil,name:"Same") }
    key=tree.recordings.active.keys.sole
    value=key.save_translation!(sheet.default_language,"Original")
    assert_equal [:rejected,:saved],race { Recording.find(key.id).save_translation!(sheet.default_language,"Edit #{Thread.current.object_id}",expected:value.lock_version,existing_id:value.id) }
    assert_equal 1,key.children.active.texts.count
    assert_equal 1,key.children.active.texts.sole.lock_version
  ensure
    project&.destroy!
  end
end
