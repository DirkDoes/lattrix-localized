ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort "Refusing to run tests outside a test database" unless ActiveRecord::Base.connection_db_config.database.end_with?("_test")
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    def email_code_from_last_delivery
      mail = ActionMailer::Base.deliveries.last
      (mail.html_part || mail).body.decoded[/\b\d{6}\b/]
    end
  end
end
