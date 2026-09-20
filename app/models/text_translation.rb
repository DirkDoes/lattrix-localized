class TextTranslation < ApplicationRecord
  include Recordable
  belongs_to :language
  validates :text, length: {minimum: 1, maximum: 100_000}, allow_nil: false
end
