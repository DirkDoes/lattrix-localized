require "test_helper"

class ProjectCapacityConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "simultaneous invitations cannot both take the last member place" do
    project = Project.create!(name: "Concurrent capacity #{SecureRandom.hex(4)}")
    rows = 201.times.map do |i|
      { id: SecureRandom.uuid, email: "#{project.id}-#{i}@example.com", name: "Member #{i}", email_verified_at: Time.current }
    end
    User.insert_all!(rows)
    ProjectMembership.insert_all!(rows.first(199).map { |row| { user_id: row[:id], project_id: project.id, role: "viewer" } })
    invites = rows.last(2).map { |row| project.project_invites.create!(email: row[:email]) }
    ready = Queue.new
    start = Queue.new
    workers = invites.zip(rows.last(2)).map do |invite, row|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          invitation = ProjectInvite.find(invite.id)
          user = User.find(row[:id])
          ready << true
          start.pop
          begin
            invitation.accept!(user)
            true
          rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid
            false
          end
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    assert_equal [false, true], workers.map(&:value).sort_by(&:to_s)
    assert_equal 200, project.project_memberships.count
    assert_equal 1, project.project_invites.count
  ensure
    workers&.each(&:join)
    project&.destroy!
    User.where(id: rows&.pluck(:id)).delete_all if rows
  end
end
