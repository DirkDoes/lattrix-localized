class ConnectVerifiedEmailIdentities < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      INSERT INTO auth_identities (user_id, provider, provider_uid, created_at, updated_at)
      SELECT id, 'email_code', id::text, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM users WHERE email_verified_at IS NOT NULL
      ON CONFLICT DO NOTHING
    SQL
  end

  def down
    # Existing connections cannot be distinguished from backfilled ones; preserve them.
  end
end
