class RecordLocalAuthenticationIdentities < ActiveRecord::Migration[8.1]
  def up
    # Preserve the login methods existing accounts could use before this migration.
    execute <<~SQL
      INSERT INTO auth_identities (id, user_id, provider, provider_uid, created_at, updated_at)
      SELECT gen_random_uuid(), id, 'password', id::text, NOW(), NOW() FROM users
      WHERE encrypted_password <> '' ON CONFLICT DO NOTHING
    SQL
    execute <<~SQL
      INSERT INTO auth_identities (id, user_id, provider, provider_uid, created_at, updated_at)
      SELECT gen_random_uuid(), id, 'email_code', id::text, NOW(), NOW() FROM users
      WHERE email_verified_at IS NOT NULL ON CONFLICT DO NOTHING
    SQL
  end

  def down
    execute "DELETE FROM auth_identities WHERE provider IN ('password', 'email_code')"
  end
end
