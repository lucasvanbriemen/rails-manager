# Encryption keys for `encrypts` columns (App#master_key, App#env_text) come from
# the environment (loaded from .env by dotenv). Keep them out of git. Generate a
# fresh set with `bin/rails db:encryption:init` or `openssl rand -hex 16`.
if ENV["AR_ENCRYPTION_PRIMARY_KEY"].present?
  Rails.application.configure do
    config.active_record.encryption.primary_key            = ENV["AR_ENCRYPTION_PRIMARY_KEY"]
    config.active_record.encryption.deterministic_key      = ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"]
    config.active_record.encryption.key_derivation_salt    = ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"]
    config.active_record.encryption.support_unencrypted_data = true
  end
end
