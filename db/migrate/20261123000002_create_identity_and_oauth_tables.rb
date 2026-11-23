class CreateIdentityAndOauthTables < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: :uuid do |t|
      t.string :email, null: false
      t.string :password_digest, null: false
      t.string :namespace, null: false
      t.boolean :admin, null: false, default: false
      t.datetime :disabled_at
      t.timestamps
    end
    add_index :users, "LOWER(email)", unique: true, name: "index_users_on_lower_email"
    add_index :users, "LOWER(namespace)", unique: true, name: "index_users_on_lower_namespace"

    create_table :sessions, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :token_digest, null: false
      t.string :ip_address
      t.string :user_agent
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :sessions, :token_digest, unique: true

    create_table :publications, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :slug, null: false, default: "default"
      t.string :title, null: false
      t.text :description
      t.string :visibility, null: false, default: "public"
      t.timestamps
    end
    add_index :publications, [ :user_id, :slug ], unique: true

    # Doorkeeper OAuth 2.1 tables (UUID PKs, PKCE, hashed secrets, dynamic client registration)
    create_table :oauth_applications, id: :uuid do |t|
      t.string :name, null: false
      t.string :uid, null: false
      t.string :secret, null: false
      t.text :redirect_uri, null: false
      t.string :scopes, null: false, default: ""
      t.boolean :confidential, null: false, default: true
      t.timestamps null: false
    end
    add_index :oauth_applications, :uid, unique: true

    create_table :oauth_access_grants, id: :uuid do |t|
      t.references :resource_owner, null: false, type: :uuid, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :application, null: false, type: :uuid, foreign_key: { to_table: :oauth_applications, on_delete: :cascade }
      t.string :token, null: false
      t.integer :expires_in, null: false
      t.text :redirect_uri, null: false
      t.string :scopes, null: false, default: ""
      t.string :code_challenge
      t.string :code_challenge_method
      t.datetime :created_at, null: false
      t.datetime :revoked_at
    end
    add_index :oauth_access_grants, :token, unique: true

    create_table :oauth_access_tokens, id: :uuid do |t|
      t.references :resource_owner, type: :uuid, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :application, null: false, type: :uuid, foreign_key: { to_table: :oauth_applications, on_delete: :cascade }
      t.string :token, null: false
      t.string :refresh_token
      t.integer :expires_in
      t.string :scopes
      t.datetime :created_at, null: false
      t.datetime :revoked_at
      t.string :previous_refresh_token, null: false, default: ""
    end
    add_index :oauth_access_tokens, :token, unique: true
    add_index :oauth_access_tokens, :refresh_token, unique: true
  end
end
