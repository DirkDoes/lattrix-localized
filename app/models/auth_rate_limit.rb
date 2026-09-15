class AuthRateLimit < ApplicationRecord
  class Exceeded < StandardError
    attr_reader :retry_after

    def initialize(retry_after)
      @retry_after = retry_after
      minutes, seconds = retry_after.divmod(60)
      wait = [[minutes, "minute"], [seconds, "second"]].filter_map do |amount, unit|
        "#{amount} #{unit}#{'s' unless amount == 1}" if amount.positive?
      end.join(" and ")
      super("Please wait #{wait} before you can send another request.")
    end
  end
  self.primary_key = :key

  def self.check!(key, limit:, period:)
    where("expires_at < ?", Time.current).delete_all if key.include?("global")
    bucket = Time.current.to_i / period
    digest = OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "rate:#{key}:#{bucket}")
    expiry = Time.at((bucket + 1) * period).utc
    sql = sanitize_sql_array([<<~SQL, digest, expiry, limit])
      INSERT INTO auth_rate_limits (key, count, expires_at) VALUES (?, 1, ?)
      ON CONFLICT (key) DO UPDATE SET count = auth_rate_limits.count + 1
      WHERE auth_rate_limits.count < ? RETURNING count
    SQL
    raise Exceeded.new([(expiry - Time.current).ceil, 1].max) if connection.select_value(sql).nil?
  end

  def self.request!(ip, email)
    transaction do
      where("expires_at < ?", Time.current).delete_all
      # Rejected cooldown retries must not consume the hourly mail allowance.
      check!("global", limit: 1000, period: 3600)
      check!("ip:#{ip}", limit: 30, period: 3600)
      check!("email:#{email}", limit: 5, period: 3600)
      check!("cooldown:#{email}", limit: 1, period: 30)
    end
  end
end
