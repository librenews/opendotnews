redis_url = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }

  schedule_file = Rails.root.join("config/schedule.yml")
  if File.exist?(schedule_file) && !Rails.env.test?
    schedule = YAML.safe_load(File.read(schedule_file)) || {}
    Sidekiq::Cron::Job.load_from_hash!(schedule)
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url }
end
