class Current < ActiveSupport::CurrentAttributes
  attribute :session, :user, :oauth_token, :request_id

  def session=(value)
    super
    self.user = value&.user
  end
end
