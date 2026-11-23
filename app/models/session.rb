require "digest"

class Session < ApplicationRecord
  belongs_to :user

  attr_accessor :raw_token

  def self.issue_for(user, ip_address: nil, user_agent: nil)
    raw = SecureRandom.urlsafe_base64(32)
    sess = create!(
      user: user,
      token_digest: digest(raw),
      ip_address: ip_address,
      user_agent: user_agent.to_s.truncate(255),
      last_seen_at: Time.current
    )
    sess.raw_token = raw
    sess
  end

  def self.find_by_raw_token(raw)
    return nil if raw.blank?
    find_by(token_digest: digest(raw))
  end

  def self.digest(raw)
    Digest::SHA256.hexdigest(raw.to_s)
  end
end
