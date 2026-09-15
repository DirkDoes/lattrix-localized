namespace :authentication do
  desc "List accounts without a method under the current AUTH_METHODS configuration"
  task audit: :environment do
    User.where(banned_at: nil).find_each do |user|
      puts "#{user.id} #{user.email}: no enabled sign-in method" if user.available_methods.empty?
    end
  end

  desc "Remove expired authentication challenges and limits"
  task cleanup: :environment do
    [EmailChallenge, AuthRateLimit].each { |model| model.where("expires_at < ?", Time.current).delete_all }
  end
end
