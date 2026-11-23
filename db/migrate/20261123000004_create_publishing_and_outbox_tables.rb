class CreatePublishingAndOutboxTables < ActiveRecord::Migration[8.1]
  def change
    create_table :documents, id: :uuid do |t|
      t.references :publication, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :path, null: false
      t.string :title, null: false
      t.integer :current_revision_number, null: false, default: 1
      t.string :visibility, null: false, default: "draft"
      t.datetime :published_at
      t.datetime :deleted_at
      t.string :rss_guid, null: false
      t.string :content_sha256, null: false
      t.timestamps
    end
    add_index :documents, [ :publication_id, :path ], unique: true
    add_index :documents, :rss_guid, unique: true

    create_table :document_revisions, id: :uuid do |t|
      t.references :document, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.integer :revision_number, null: false
      t.text :markdown, null: false
      t.string :sha256, null: false
      t.references :created_by_user, null: false, type: :uuid, foreign_key: { to_table: :users, on_delete: :restrict }
      t.datetime :created_at, null: false
    end
    add_index :document_revisions, [ :document_id, :revision_number ], unique: true

    create_table :outbox_events, id: :uuid do |t|
      t.string :event_type, null: false
      t.string :aggregate_type, null: false
      t.uuid :aggregate_id, null: false
      t.integer :aggregate_version, null: false, default: 1
      t.jsonb :payload, null: false, default: {}
      t.datetime :created_at, null: false
      t.datetime :dispatched_at
      t.integer :attempts, null: false, default: 0
      t.text :last_error
    end
    add_index :outbox_events, [ :aggregate_type, :aggregate_id, :aggregate_version, :event_type ],
      unique: true,
      name: "index_outbox_events_idempotency"
    add_index :outbox_events, :created_at,
      where: "dispatched_at IS NULL",
      name: "index_outbox_events_undispatched"

    create_table :idempotency_keys, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :operation, null: false
      t.string :client_key, null: false
      t.string :request_hash, null: false
      t.jsonb :result_reference, null: false, default: {}
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :idempotency_keys, [ :user_id, :operation, :client_key ], unique: true

    create_table :audit_logs, id: :uuid do |t|
      t.references :user, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :actor_type, null: false, default: "user"
      t.string :action, null: false
      t.string :resource_type
      t.string :resource_id
      t.string :scope
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :audit_logs, [ :user_id, :created_at ], order: { created_at: :desc }
  end
end
