class RecordingEventPolicy < ApplicationPolicy
  def restore?
    SheetPolicy.new(user, record.recording.sheet).manage_keys?
  end
end
