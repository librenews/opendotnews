class CreateUpstreamPushTables < ActiveRecord::Migration[8.1]
  def change
    create_table :upstream_push_subscriptions, id: :uuid do |t|
      t.references :feed, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :protocol, null: false
      t.string :hub_url, null: false
      t.string :topic_url, null: false
      t.string :callback_token_digest, null: false
      t.text :callback_token, null: false
      t.text :secret
      t.string :status, null: false, default: "pending"
      t.string :requested_mode, null: false, default: "subscribe"
      t.integer :lease_seconds
      t.datetime :lease_expires_at
      t.datetime :last_requested_at
      t.datetime :last_confirmed_at
      t.datetime :last_delivery_at
      t.datetime :next_renew_at
      t.integer :failure_count, null: false, default: 0
      t.text :last_error
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :upstream_push_subscriptions, :callback_token_digest, unique: true
    add_index :upstream_push_subscriptions, [ :feed_id, :protocol, :hub_url, :topic_url ],
      unique: true,
      where: "status IN ('pending', 'active', 'unsubscribing')",
      name: "index_active_upstream_push_subscriptions"
    add_index :upstream_push_subscriptions, [ :status, :next_renew_at ],
      name: "index_upstream_push_renewals"
    add_index :upstream_push_subscriptions, [ :status, :lease_expires_at ],
      name: "index_upstream_push_expirations"

    create_table :staged_push_payloads, id: :uuid do |t|
      t.references :upstream_push_subscription, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :feed, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :content_type
      t.jsonb :headers, null: false, default: {}
      t.text :body, null: false
      t.string :body_sha256, null: false
      t.string :status, null: false, default: "pending"
      t.text :error_message
      t.datetime :received_at, null: false
      t.datetime :processed_at
      t.timestamps
    end

    add_index :staged_push_payloads, [ :status, :received_at ]
  end
end
