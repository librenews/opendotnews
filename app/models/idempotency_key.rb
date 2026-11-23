class IdempotencyKey < ApplicationRecord
  belongs_to :user

  validates :operation, :client_key, :request_hash, :expires_at, presence: true
  validates :client_key, uniqueness: { scope: [ :user_id, :operation ] }
end
