module AuthenticationPolicy
  PROVIDERS = { "google" => "google_oauth2", "github" => "github", "discord" => "discord" }.freeze
  def self.methods
    ENV.fetch("AUTH_METHODS", "password,email_code").split(",").map(&:strip).uniq
  end

  def self.enabled?(method)
    methods.include?(method.to_s)
  end

  def self.providers
    PROVIDERS.select { |name, _| enabled?(name) }
  end

  def self.validate!
    raise "AUTH_METHODS must contain supported login methods" if methods.empty? || (methods - (PROVIDERS.keys + %w[password email_code])).any?
    providers.each_key do |name|
      %w[CLIENT_ID CLIENT_SECRET].each do |suffix|
        raise "Missing #{name.upcase}_#{suffix}" if ENV["#{name.upcase}_#{suffix}"].blank?
      end
    end
  end
end
