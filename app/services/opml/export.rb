require "nokogiri"

module Opml
  class Export
    def self.call(user:)
      new(user: user).call
    end

    def initialize(user:)
      @user = user
    end

    def call
      subs = UserFeedSubscription.active
        .includes(:feed)
        .where(user_id: @user.id)
        .order(Arel.sql("COALESCE(folder_name, '') ASC, subscribed_at ASC"))

      grouped = subs.group_by { |s| s.folder_name.presence }

      builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.opml(version: "2.0") do
          xml.head do
            xml.title "Open.News Subscriptions (#{@user.namespace})"
            xml.dateCreated Time.current.rfc2822
          end
          xml.body do
            # Uncategorized top-level feeds
            Array(grouped[nil]).each do |sub|
              emit_feed_outline(xml, sub.feed)
            end

            # Folder-grouped feeds
            grouped.each do |folder, folder_subs|
              next if folder.nil?

              xml.outline(text: folder, title: folder) do
                folder_subs.each do |sub|
                  emit_feed_outline(xml, sub.feed)
                end
              end
            end
          end
        end
      end

      builder.to_xml
    end

    private

    def emit_feed_outline(xml, feed)
      attrs = {
        type: feed.format == "atom" ? "rss" : "rss",
        text: feed.title.presence || feed.canonical_url,
        title: feed.title.presence || feed.canonical_url,
        xmlUrl: feed.canonical_url
      }
      attrs[:htmlUrl] = feed.site_url if feed.site_url.present?
      xml.outline(attrs)
    end
  end
end
