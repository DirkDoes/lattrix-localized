class MembershipLanguage < ApplicationRecord
  belongs_to :project_membership
  belongs_to :language
  validates :language_id, uniqueness: {scope: :project_membership_id}
  validate do
    errors.add(:language, "belongs to another project") if language.project_id != project_membership.project_id
  end
end
