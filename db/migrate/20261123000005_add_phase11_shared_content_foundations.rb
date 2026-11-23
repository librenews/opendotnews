class AddPhase11SharedContentFoundations < ActiveRecord::Migration[8.1]
  def change
    # 1. Extensible source metadata & operational fetch/push diagnostics on feeds
    add_column :feeds, :source_type, :string, null: false, default: "feed"
    add_column :feeds, :source_metadata, :jsonb, null: false, default: {}
    add_column :feeds, :last_successful_fetch_at, :datetime
    add_column :feeds, :last_http_status, :integer
    add_column :feeds, :last_fetch_duration_ms, :integer
    add_column :feeds, :last_error_at, :datetime
    add_column :feeds, :last_ingestion_method, :string
    add_column :feeds, :last_diagnostics, :jsonb, null: false, default: {}
    add_index :feeds, :source_type

    # 2. Adapter-extensible item metadata & canonical URL index for dedupe fallback
    add_column :feed_items, :metadata, :jsonb, null: false, default: {}
    add_index :feed_items, [ :feed_id, :external_url ],
      where: "external_url IS NOT NULL",
      name: "index_feed_items_on_feed_id_and_external_url"

    # 3. Lazy per-user item state (created only on explicit user interaction, never eagerly on ingest)
    create_table :user_items, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :feed_item, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.datetime :read_at
      t.datetime :saved_at
      t.datetime :archived_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :user_items, [ :user_id, :feed_item_id ], unique: true
    add_index :user_items, [ :user_id, :saved_at ],
      where: "saved_at IS NOT NULL",
      name: "index_user_items_on_user_saved"
    add_index :user_items, [ :user_id, :read_at ],
      where: "read_at IS NOT NULL",
      name: "index_user_items_on_user_read"
    add_index :user_items, [ :user_id, :archived_at ],
      where: "archived_at IS NOT NULL",
      name: "index_user_items_on_user_archived"
  end
end
