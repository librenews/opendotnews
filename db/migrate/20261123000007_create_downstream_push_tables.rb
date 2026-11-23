class CreateDownstreamPushTables < ActiveRecord::Migration[8.1]
  def change
    create_table :downstream_subscriptions, id: :uuid do |t|
      t.references :publication, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :protocol, null: false
      t.string :topic_url, null: false
      t.string :topic_format, null: false
      t.string :callback_url, null: false
      t.string :callback_host, null: false
      t.text :secret
      t.string :status, null: false, default: "pending"
      t.string :verification_challenge_digest
      t.datetime :verification_expires_at
      t.integer :lease_seconds
      t.datetime :lease_expires_at
      t.integer :failure_count, null: false, default: 0
      t.datetime :last_delivered_at
      t.text :last_error
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :downstream_subscriptions, [ :protocol, :topic_url, :callback_url ],
      unique: true,
      name: "index_downstream_subscriptions_identity"
    add_index :downstream_subscriptions, [ :publication_id, :status ],
      name: "index_downstream_subs_by_pub_status"
    add_index :downstream_subscriptions, [ :status, :lease_expires_at ],
      name: "index_downstream_subs_expirations"
    add_index :downstream_subscriptions, :callback_host

    create_table :delivery_attempts, id: :uuid do |t|
      t.references :downstream_subscription, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :outbox_event, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.integer :attempt_number, null: false, default: 1
      t.string :status, null: false, default: "pending"
      t.integer :http_status
      t.text :last_error
      t.datetime :next_attempt_at
      t.datetime :delivered_at
      t.timestamps
    end

    add_index :delivery_attempts, [ :downstream_subscription_id, :outbox_event_id, :attempt_number ],
      unique: true,
      name: "index_delivery_attempts_uniqueness"
    add_index :delivery_attempts, :next_attempt_at,
      where: "status = 'retry_scheduled'",
      name: "index_delivery_attempts_retry_due"
  end
end
