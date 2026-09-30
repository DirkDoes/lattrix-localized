class CatalogDailyJob < ApplicationJob
  def perform
    Project.where.not(repository: [nil, ""]).find_each { |project| CatalogSyncJob.perform_later(project.id, publish: true, initial: project.git_sha.nil?) }
  end
end
