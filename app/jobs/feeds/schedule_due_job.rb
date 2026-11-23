module Feeds
  class ScheduleDueJob
    include Sidekiq::Job

    sidekiq_options queue: "scheduled", retry: 2

    def perform(limit = 200)
      Feeds::Schedule.enqueue_due!(limit: limit)
    end
  end
end
