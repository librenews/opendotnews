module OpenNews
  Config = Data.define(
    :app_base_url,
    :feed_poll_interval,
    :feed_max_bytes,
    :feed_max_decompressed_bytes,
    :feed_http_timeout,
    :feed_max_redirects,
    :opml_max_bytes,
    :opml_max_feeds,
    :inbox_retention_days,
    :user_agent,
    :allow_private_http_fetch
  )

  def self.config
    @config ||= Config.new(
      app_base_url: ENV.fetch("APP_BASE_URL", "http://localhost:3000").chomp("/"),
      feed_poll_interval: ENV.fetch("FEED_POLL_INTERVAL_MINUTES", "15").to_i.minutes,
      feed_max_bytes: ENV.fetch("FEED_MAX_BYTES", (5 * 1024 * 1024).to_s).to_i,
      feed_max_decompressed_bytes: ENV.fetch("FEED_MAX_DECOMPRESSED_BYTES", (10 * 1024 * 1024).to_s).to_i,
      feed_http_timeout: ENV.fetch("FEED_HTTP_TIMEOUT_SECONDS", "15").to_i,
      feed_max_redirects: ENV.fetch("FEED_MAX_REDIRECTS", "5").to_i,
      opml_max_bytes: ENV.fetch("OPML_MAX_BYTES", (2 * 1024 * 1024).to_s).to_i,
      opml_max_feeds: ENV.fetch("OPML_MAX_FEEDS", "2000").to_i,
      inbox_retention_days: ENV.fetch("INBOX_RETENTION_DAYS", "90").to_i,
      user_agent: ENV.fetch("OPEN_NEWS_USER_AGENT", "OpenNews/1.0 (+https://open.news)"),
      allow_private_http_fetch: ENV["ALLOW_PRIVATE_HTTP_FETCH"] == "true"
    )
  end

  def self.reset_config!
    @config = nil
  end
end
