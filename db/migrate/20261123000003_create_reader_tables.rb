class CreateReaderTables < ActiveRecord::Migration[8.1]
  def change
    create_table :feeds, id: :uuid do |t|
      t.string :canonical_url, null: false
      t.string :site_url
      t.string :title
      t.text :description
      t.string :format
      t.string :etag
      t.string :last_modified
      t.string :content_hash
      t.datetime :last_fetched_at
      t.datetime :next_fetch_at
      t.datetime :last_changed_at
      t.datetime :fetching_started_at
      t.integer :fetch_failure_count, null: false, default: 0
      t.text :last_error
      t.string :status, null: false, default: "active"
      t.string :discovered_websub_hub
      t.string :discovered_websub_topic
      t.string :discovered_rsscloud_endpoint
      t.string :discovered_rsscloud_protocol
      t.timestamps
    end
    add_index :feeds, :canonical_url, unique: true
    add_index :feeds, [ :status, :next_fetch_at ]

    create_table :feed_aliases, id: :uuid do |t|
      t.references :feed, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :url, null: false
      t.string :reason, null: false
      t.timestamps
    end
    add_index :feed_aliases, :url, unique: true

    create_table :feed_items, id: :uuid do |t|
      t.references :feed, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :external_id, null: false
      t.string :external_url
      t.string :title
      t.string :author
      t.text :summary_text
      t.text :content_html_sanitized
      t.text :content_text
      t.datetime :published_at
      t.datetime :source_updated_at
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.string :content_hash, null: false
      t.integer :current_revision_number, null: false, default: 1
      t.boolean :is_deleted, null: false, default: false
      t.timestamps
    end

    # PostgreSQL stored generated weighted tsvector for fast authorized full-text search
    execute <<~SQL
      ALTER TABLE feed_items
      ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(summary_text, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(content_text, '')), 'C')
      ) STORED;
    SQL

    add_index :feed_items, [ :feed_id, :external_id ], unique: true
    add_index :feed_items, [ :feed_id, :published_at ], order: { published_at: :desc }
    add_index :feed_items, [ :feed_id, :first_seen_at ], order: { first_seen_at: :desc }
    add_index :feed_items, :search_vector, using: :gin

    create_table :feed_item_revisions, id: :uuid do |t|
      t.references :feed_item, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.integer :revision_number, null: false
      t.string :content_hash, null: false
      t.jsonb :payload_snapshot, null: false, default: {}
      t.datetime :recorded_at, null: false
    end
    add_index :feed_item_revisions, [ :feed_item_id, :revision_number ], unique: true

    create_table :user_feed_subscriptions, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :feed, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :folder_name
      t.datetime :subscribed_at, null: false
      t.datetime :unsubscribed_at
      t.timestamps
    end
    add_index :user_feed_subscriptions, [ :user_id, :feed_id ],
      unique: true,
      where: "unsubscribed_at IS NULL",
      name: "index_active_user_feed_subscriptions"
    add_index :user_feed_subscriptions, [ :feed_id ],
      where: "unsubscribed_at IS NULL",
      name: "index_active_subscriptions_by_feed"

    # Monotonic bigint cursor for durable personal-agent inbox
    create_table :user_inbox_events, id: :bigserial do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :event_type, null: false
      t.references :feed, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :feed_item, type: :uuid, foreign_key: { on_delete: :nullify }
      t.uuid :document_id
      t.uuid :outbox_event_id, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :user_inbox_events, [ :user_id, :outbox_event_id ], unique: true
    add_index :user_inbox_events, [ :user_id, :id ], order: { id: :desc }
    add_index :user_inbox_events, :created_at

    create_table :opml_imports, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :status, null: false, default: "pending"
      t.integer :total_count, null: false, default: 0
      t.integer :success_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.integer :error_count, null: false, default: 0
      t.jsonb :error_summary, null: false, default: []
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end
  end
end
