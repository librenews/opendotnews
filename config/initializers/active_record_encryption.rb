# Configure Active Record Encryption for at-rest protection of WebSub secrets and callback tokens.
# Production MUST provide ACTIVE_RECORD_ENCRYPTION_* via environment variables (see docs/DEPLOYMENT.md).
# Development and test fall back to deterministic local keys so fresh checkouts boot with zero setup.
Rails.application.configure do
  primary_key = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]
  deterministic_key = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]
  key_derivation_salt = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]

  if primary_key.blank? && !Rails.env.production?
    primary_key = "open-news-dev-primary-encryption-key-32b"
    deterministic_key = "open-news-dev-deterministic-key-32bytes"
    key_derivation_salt = "open-news-dev-key-derivation-salt-32byt"
  end

  if primary_key.present? && deterministic_key.present? && key_derivation_salt.present?
    config.active_record.encryption.primary_key = primary_key
    config.active_record.encryption.deterministic_key = deterministic_key
    config.active_record.encryption.key_derivation_salt = key_derivation_salt
  end
end
