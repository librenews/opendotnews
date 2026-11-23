source "https://rubygems.org"

gem "rails", "~> 8.1.4", ">= 8.1.4.1"
gem "propshaft"
gem "pg", "~> 1.5"
gem "puma", ">= 6.0"
gem "bcrypt", "~> 3.1.7"
gem "bootsnap", require: false
gem "thruster", require: false

# Background jobs & recurring schedules
gem "sidekiq", "~> 7.3"
gem "sidekiq-cron", "~> 2.0"

# OAuth 2.1 provider (Authorization Code + PKCE + scopes + hashed tokens)
gem "doorkeeper", "~> 5.7"

# Strict XML/HTML parsing and sanitization
gem "nokogiri", "~> 1.18"
gem "loofah", "~> 2.24"

# Rate limiting & abuse protection
gem "rack-attack", "~> 6.7"

gem "tzinfo-data", platforms: %i[ windows jruby ]

group :development, :test do
  gem "dotenv-rails", "~> 3.1"
  gem "rspec-rails", "~> 8.1"
  gem "factory_bot_rails", "~> 6.4"
  gem "webmock", "~> 3.24"
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"
  gem "bundler-audit", require: false
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
end

group :development do
  gem "web-console"
end
