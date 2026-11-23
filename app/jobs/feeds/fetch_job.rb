module Feeds
  class FetchJob
    include Sidekiq::Job

    sidekiq_options queue: "ingestion", retry: 3

    def perform(feed_id)
      feed = Feed.find_by(id: feed_id)
      return unless feed

      Feeds::Fetch.call(feed)
    end
  end
end
