module Recordable
  extend ActiveSupport::Concern
  included do
    has_many :recordings, as: :recordable
    has_many :recording_events, as: :recordable
    before_update { raise ActiveRecord::ReadOnlyRecord, "Payloads are immutable" }
    before_destroy { raise ActiveRecord::ReadOnlyRecord, "Payloads are immutable" }
  end
end
