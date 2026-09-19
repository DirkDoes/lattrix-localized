module Sluggable
  extend ActiveSupport::Concern

  included do
    normalizes :slug, with: ->(slug) { slug.strip.downcase }
    before_validation :assign_slug, on: :create
    validates :slug, presence: true, length: { maximum: 100 },
      format: { with: /\A[a-z0-9]+(?:[-_][a-z0-9]+)*\z/ },
      exclusion: { in: %w[new edit] }
  end

  def to_param
    slug
  end

  private

  def assign_slug
    return if slug.present?
    separator = "_"
    base = name.to_s.parameterize(separator: separator).first(90).sub(/[-_]+\z/, "").presence || self.class.model_name.singular
    base = "#{base}-1" if %w[new edit].include?(base)
    scope = self.class.all
    scope = scope.where(workspace_id: workspace_id) if is_a?(Project)
    self.slug = base
    suffix = 2
    while scope.exists?(slug: slug)
      self.slug = "#{base}-#{suffix}"
      suffix += 1
    end
  end
end
