class AuditLog < ApplicationRecord
  belongs_to :user, optional: true

  validates :action, presence: true

  def self.record!(action:, user: nil, actor_type: "user", resource_type: nil, resource_id: nil, scope: nil, metadata: {})
    create!(
      user: user,
      actor_type: actor_type,
      action: action,
      resource_type: resource_type,
      resource_id: resource_id&.to_s,
      scope: scope,
      metadata: metadata,
      created_at: Time.current
    )
  end
end
