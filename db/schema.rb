# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_14_040000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "auth_identities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name"
    t.string "provider", null: false
    t.string "provider_uid", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["provider", "provider_uid"], name: "index_auth_identities_on_provider_and_provider_uid", unique: true
    t.index ["user_id", "provider"], name: "index_auth_identities_on_user_id_and_provider", unique: true
    t.index ["user_id"], name: "index_auth_identities_on_user_id"
  end

  create_table "auth_rate_limits", primary_key: "key", id: :string, force: :cascade do |t|
    t.integer "count", default: 0, null: false
    t.datetime "expires_at", null: false
    t.index ["expires_at"], name: "index_auth_rate_limits_on_expires_at"
  end

  create_table "email_challenges", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.string "digest", null: false
    t.string "email", null: false
    t.datetime "expires_at", null: false
    t.string "name"
    t.string "password_digest"
    t.string "purpose", null: false
    t.datetime "updated_at", null: false
    t.index ["email", "purpose"], name: "index_email_challenges_on_email_and_purpose", unique: true
    t.index ["expires_at"], name: "index_email_challenges_on_expires_at"
  end

  create_table "invitations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "expires_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_invitations_on_email", unique: true
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "access_granted_at"
    t.datetime "banned_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "email_verified_at"
    t.string "encrypted_password", default: "", null: false
    t.string "name"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.integer "role", default: 0, null: false
    t.string "theme_preference", default: "system", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_normalized_email", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "auth_identities", "users"
end
