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

ActiveRecord::Schema[8.1].define(version: 2026_11_23_000008) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "audit_logs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id"
    t.string "actor_type", default: "user", null: false
    t.string "action", null: false
    t.string "resource_type"
    t.string "resource_id"
    t.string "scope"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["user_id", "created_at"], name: "index_audit_logs_on_user_id_and_created_at", order: { created_at: :desc }
    t.index ["user_id"], name: "index_audit_logs_on_user_id"
  end

  create_table "delivery_attempts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "downstream_subscription_id", null: false
    t.uuid "outbox_event_id", null: false
    t.integer "attempt_number", default: 1, null: false
    t.string "status", default: "pending", null: false
    t.integer "http_status"
    t.text "last_error"
    t.datetime "next_attempt_at"
    t.datetime "delivered_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["downstream_subscription_id", "outbox_event_id", "attempt_number"], name: "index_delivery_attempts_uniqueness", unique: true
    t.index ["downstream_subscription_id"], name: "index_delivery_attempts_on_downstream_subscription_id"
    t.index ["next_attempt_at"], name: "index_delivery_attempts_retry_due", where: "((status)::text = 'retry_scheduled'::text)"
    t.index ["outbox_event_id"], name: "index_delivery_attempts_on_outbox_event_id"
  end

  create_table "document_revisions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "document_id", null: false
    t.integer "revision_number", null: false
    t.text "markdown", null: false
    t.string "sha256", null: false
    t.uuid "created_by_user_id", null: false
    t.datetime "created_at", null: false
    t.index ["created_by_user_id"], name: "index_document_revisions_on_created_by_user_id"
    t.index ["document_id", "revision_number"], name: "index_document_revisions_on_document_id_and_revision_number", unique: true
    t.index ["document_id"], name: "index_document_revisions_on_document_id"
  end

  create_table "documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "publication_id", null: false
    t.string "path", null: false
    t.string "title", null: false
    t.integer "current_revision_number", default: 1, null: false
    t.string "visibility", default: "draft", null: false
    t.datetime "published_at"
    t.datetime "deleted_at"
    t.string "rss_guid", null: false
    t.string "content_sha256", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "moderated_at"
    t.text "moderation_reason"
    t.index ["moderated_at"], name: "index_documents_on_moderated_at", where: "(moderated_at IS NOT NULL)"
    t.index ["publication_id", "path"], name: "index_documents_on_publication_id_and_path", unique: true
    t.index ["publication_id"], name: "index_documents_on_publication_id"
    t.index ["rss_guid"], name: "index_documents_on_rss_guid", unique: true
  end

  create_table "downstream_subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "publication_id", null: false
    t.string "protocol", null: false
    t.string "topic_url", null: false
    t.string "topic_format", null: false
    t.string "callback_url", null: false
    t.string "callback_host", null: false
    t.text "secret"
    t.string "status", default: "pending", null: false
    t.string "verification_challenge_digest"
    t.datetime "verification_expires_at"
    t.integer "lease_seconds"
    t.datetime "lease_expires_at"
    t.integer "failure_count", default: 0, null: false
    t.datetime "last_delivered_at"
    t.text "last_error"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["callback_host"], name: "index_downstream_subscriptions_on_callback_host"
    t.index ["protocol", "topic_url", "callback_url"], name: "index_downstream_subscriptions_identity", unique: true
    t.index ["publication_id", "status"], name: "index_downstream_subs_by_pub_status"
    t.index ["publication_id"], name: "index_downstream_subscriptions_on_publication_id"
    t.index ["status", "lease_expires_at"], name: "index_downstream_subs_expirations"
  end

  create_table "feed_aliases", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "feed_id", null: false
    t.string "url", null: false
    t.string "reason", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["feed_id"], name: "index_feed_aliases_on_feed_id"
    t.index ["url"], name: "index_feed_aliases_on_url", unique: true
  end

  create_table "feed_item_revisions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "feed_item_id", null: false
    t.integer "revision_number", null: false
    t.string "content_hash", null: false
    t.jsonb "payload_snapshot", default: {}, null: false
    t.datetime "recorded_at", null: false
    t.index ["feed_item_id", "revision_number"], name: "index_feed_item_revisions_on_feed_item_id_and_revision_number", unique: true
    t.index ["feed_item_id"], name: "index_feed_item_revisions_on_feed_item_id"
  end

  create_table "feed_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "feed_id", null: false
    t.string "external_id", null: false
    t.string "external_url"
    t.string "title"
    t.string "author"
    t.text "summary_text"
    t.text "content_html_sanitized"
    t.text "content_text"
    t.datetime "published_at"
    t.datetime "source_updated_at"
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.string "content_hash", null: false
    t.integer "current_revision_number", default: 1, null: false
    t.boolean "is_deleted", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.virtual "search_vector", type: :tsvector, as: "((setweight(to_tsvector('english'::regconfig, (COALESCE(title, ''::character varying))::text), 'A'::\"char\") || setweight(to_tsvector('english'::regconfig, COALESCE(summary_text, ''::text)), 'B'::\"char\")) || setweight(to_tsvector('english'::regconfig, COALESCE(content_text, ''::text)), 'C'::\"char\"))", stored: true
    t.jsonb "metadata", default: {}, null: false
    t.index ["feed_id", "external_id"], name: "index_feed_items_on_feed_id_and_external_id", unique: true
    t.index ["feed_id", "external_url"], name: "index_feed_items_on_feed_id_and_external_url", where: "(external_url IS NOT NULL)"
    t.index ["feed_id", "first_seen_at"], name: "index_feed_items_on_feed_id_and_first_seen_at", order: { first_seen_at: :desc }
    t.index ["feed_id", "published_at"], name: "index_feed_items_on_feed_id_and_published_at", order: { published_at: :desc }
    t.index ["feed_id"], name: "index_feed_items_on_feed_id"
    t.index ["search_vector"], name: "index_feed_items_on_search_vector", using: :gin
  end

  create_table "feeds", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "canonical_url", null: false
    t.string "site_url"
    t.string "title"
    t.text "description"
    t.string "format"
    t.string "etag"
    t.string "last_modified"
    t.string "content_hash"
    t.datetime "last_fetched_at"
    t.datetime "next_fetch_at"
    t.datetime "last_changed_at"
    t.datetime "fetching_started_at"
    t.integer "fetch_failure_count", default: 0, null: false
    t.text "last_error"
    t.string "status", default: "active", null: false
    t.string "discovered_websub_hub"
    t.string "discovered_websub_topic"
    t.string "discovered_rsscloud_endpoint"
    t.string "discovered_rsscloud_protocol"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "source_type", default: "feed", null: false
    t.jsonb "source_metadata", default: {}, null: false
    t.datetime "last_successful_fetch_at"
    t.integer "last_http_status"
    t.integer "last_fetch_duration_ms"
    t.datetime "last_error_at"
    t.string "last_ingestion_method"
    t.jsonb "last_diagnostics", default: {}, null: false
    t.index ["canonical_url"], name: "index_feeds_on_canonical_url", unique: true
    t.index ["source_type"], name: "index_feeds_on_source_type"
    t.index ["status", "next_fetch_at"], name: "index_feeds_on_status_and_next_fetch_at"
  end

  create_table "idempotency_keys", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "operation", null: false
    t.string "client_key", null: false
    t.string "request_hash", null: false
    t.jsonb "result_reference", default: {}, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "operation", "client_key"], name: "index_idempotency_keys_on_user_id_and_operation_and_client_key", unique: true
    t.index ["user_id"], name: "index_idempotency_keys_on_user_id"
  end

  create_table "oauth_access_grants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "resource_owner_id", null: false
    t.uuid "application_id", null: false
    t.string "token", null: false
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.string "code_challenge"
    t.string "code_challenge_method"
    t.datetime "created_at", null: false
    t.datetime "revoked_at"
    t.index ["application_id"], name: "index_oauth_access_grants_on_application_id"
    t.index ["resource_owner_id"], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "resource_owner_id"
    t.uuid "application_id", null: false
    t.string "token", null: false
    t.string "refresh_token"
    t.integer "expires_in"
    t.string "scopes"
    t.datetime "created_at", null: false
    t.datetime "revoked_at"
    t.string "previous_refresh_token", default: "", null: false
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "uid", null: false
    t.string "secret", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
  end

  create_table "opml_imports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "status", default: "pending", null: false
    t.integer "total_count", default: 0, null: false
    t.integer "success_count", default: 0, null: false
    t.integer "skipped_count", default: 0, null: false
    t.integer "error_count", default: 0, null: false
    t.jsonb "error_summary", default: [], null: false
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_opml_imports_on_user_id"
  end

  create_table "outbox_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "event_type", null: false
    t.string "aggregate_type", null: false
    t.uuid "aggregate_id", null: false
    t.integer "aggregate_version", default: 1, null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "dispatched_at"
    t.integer "attempts", default: 0, null: false
    t.text "last_error"
    t.index ["aggregate_type", "aggregate_id", "aggregate_version", "event_type"], name: "index_outbox_events_idempotency", unique: true
    t.index ["created_at"], name: "index_outbox_events_undispatched", where: "(dispatched_at IS NULL)"
  end

  create_table "publications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "slug", default: "default", null: false
    t.string "title", null: false
    t.text "description"
    t.string "visibility", default: "public", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "slug"], name: "index_publications_on_user_id_and_slug", unique: true
    t.index ["user_id"], name: "index_publications_on_user_id"
  end

  create_table "sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "token_digest", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "last_seen_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_sessions_on_token_digest", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "staged_push_payloads", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "upstream_push_subscription_id", null: false
    t.uuid "feed_id", null: false
    t.string "content_type"
    t.jsonb "headers", default: {}, null: false
    t.text "body", null: false
    t.string "body_sha256", null: false
    t.string "status", default: "pending", null: false
    t.text "error_message"
    t.datetime "received_at", null: false
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["feed_id"], name: "index_staged_push_payloads_on_feed_id"
    t.index ["status", "received_at"], name: "index_staged_push_payloads_on_status_and_received_at"
    t.index ["upstream_push_subscription_id"], name: "index_staged_push_payloads_on_upstream_push_subscription_id"
  end

  create_table "upstream_push_subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "feed_id", null: false
    t.string "protocol", null: false
    t.string "hub_url", null: false
    t.string "topic_url", null: false
    t.string "callback_token_digest", null: false
    t.text "callback_token", null: false
    t.text "secret"
    t.string "status", default: "pending", null: false
    t.string "requested_mode", default: "subscribe", null: false
    t.integer "lease_seconds"
    t.datetime "lease_expires_at"
    t.datetime "last_requested_at"
    t.datetime "last_confirmed_at"
    t.datetime "last_delivery_at"
    t.datetime "next_renew_at"
    t.integer "failure_count", default: 0, null: false
    t.text "last_error"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["callback_token_digest"], name: "index_upstream_push_subscriptions_on_callback_token_digest", unique: true
    t.index ["feed_id", "protocol", "hub_url", "topic_url"], name: "index_active_upstream_push_subscriptions", unique: true, where: "((status)::text = ANY (ARRAY[('pending'::character varying)::text, ('active'::character varying)::text, ('unsubscribing'::character varying)::text]))"
    t.index ["feed_id"], name: "index_upstream_push_subscriptions_on_feed_id"
    t.index ["status", "lease_expires_at"], name: "index_upstream_push_expirations"
    t.index ["status", "next_renew_at"], name: "index_upstream_push_renewals"
  end

  create_table "user_feed_subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "feed_id", null: false
    t.string "folder_name"
    t.datetime "subscribed_at", null: false
    t.datetime "unsubscribed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["feed_id"], name: "index_active_subscriptions_by_feed", where: "(unsubscribed_at IS NULL)"
    t.index ["feed_id"], name: "index_user_feed_subscriptions_on_feed_id"
    t.index ["user_id", "feed_id"], name: "index_active_user_feed_subscriptions", unique: true, where: "(unsubscribed_at IS NULL)"
    t.index ["user_id"], name: "index_user_feed_subscriptions_on_user_id"
  end

  create_table "user_inbox_events", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "event_type", null: false
    t.uuid "feed_id"
    t.uuid "feed_item_id"
    t.uuid "document_id"
    t.uuid "outbox_event_id", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_user_inbox_events_on_created_at"
    t.index ["feed_id"], name: "index_user_inbox_events_on_feed_id"
    t.index ["feed_item_id"], name: "index_user_inbox_events_on_feed_item_id"
    t.index ["user_id", "id"], name: "index_user_inbox_events_on_user_id_and_id", order: { id: :desc }
    t.index ["user_id", "outbox_event_id"], name: "index_user_inbox_events_on_user_id_and_outbox_event_id", unique: true
    t.index ["user_id"], name: "index_user_inbox_events_on_user_id"
  end

  create_table "user_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "feed_item_id", null: false
    t.datetime "read_at"
    t.datetime "saved_at"
    t.datetime "archived_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["feed_item_id"], name: "index_user_items_on_feed_item_id"
    t.index ["user_id", "archived_at"], name: "index_user_items_on_user_archived", where: "(archived_at IS NOT NULL)"
    t.index ["user_id", "feed_item_id"], name: "index_user_items_on_user_id_and_feed_item_id", unique: true
    t.index ["user_id", "read_at"], name: "index_user_items_on_user_read", where: "(read_at IS NOT NULL)"
    t.index ["user_id", "saved_at"], name: "index_user_items_on_user_saved", where: "(saved_at IS NOT NULL)"
    t.index ["user_id"], name: "index_user_items_on_user_id"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "namespace", null: false
    t.boolean "admin", default: false, null: false
    t.datetime "disabled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_users_on_lower_email", unique: true
    t.index "lower((namespace)::text)", name: "index_users_on_lower_namespace", unique: true
  end

  add_foreign_key "audit_logs", "users", on_delete: :nullify
  add_foreign_key "delivery_attempts", "downstream_subscriptions", on_delete: :cascade
  add_foreign_key "delivery_attempts", "outbox_events", on_delete: :cascade
  add_foreign_key "document_revisions", "documents", on_delete: :cascade
  add_foreign_key "document_revisions", "users", column: "created_by_user_id", on_delete: :restrict
  add_foreign_key "documents", "publications", on_delete: :cascade
  add_foreign_key "downstream_subscriptions", "publications", on_delete: :cascade
  add_foreign_key "feed_aliases", "feeds", on_delete: :cascade
  add_foreign_key "feed_item_revisions", "feed_items", on_delete: :cascade
  add_foreign_key "feed_items", "feeds", on_delete: :cascade
  add_foreign_key "idempotency_keys", "users", on_delete: :cascade
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id", on_delete: :cascade
  add_foreign_key "oauth_access_grants", "users", column: "resource_owner_id", on_delete: :cascade
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id", on_delete: :cascade
  add_foreign_key "oauth_access_tokens", "users", column: "resource_owner_id", on_delete: :cascade
  add_foreign_key "opml_imports", "users", on_delete: :cascade
  add_foreign_key "publications", "users", on_delete: :cascade
  add_foreign_key "sessions", "users", on_delete: :cascade
  add_foreign_key "staged_push_payloads", "feeds", on_delete: :cascade
  add_foreign_key "staged_push_payloads", "upstream_push_subscriptions", on_delete: :cascade
  add_foreign_key "upstream_push_subscriptions", "feeds", on_delete: :cascade
  add_foreign_key "user_feed_subscriptions", "feeds", on_delete: :cascade
  add_foreign_key "user_feed_subscriptions", "users", on_delete: :cascade
  add_foreign_key "user_inbox_events", "feed_items", on_delete: :nullify
  add_foreign_key "user_inbox_events", "feeds", on_delete: :nullify
  add_foreign_key "user_inbox_events", "users", on_delete: :cascade
  add_foreign_key "user_items", "feed_items", on_delete: :cascade
  add_foreign_key "user_items", "users", on_delete: :cascade
end
