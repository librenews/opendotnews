module UserItems
  # Lazily creates or updates per-user state (read, saved, archived) for a shared FeedItem.
  # Never eagerly creates rows during feed ingestion; enforces strict per-user authorization.
  class UpdateState
    class ForbiddenError < StandardError; end
    class NotFoundError < StandardError; end

    def self.call(user:, feed_item_id:, read: nil, saved: nil, archived: nil, metadata: nil)
      new(
        user: user,
        feed_item_id: feed_item_id,
        read: read,
        saved: saved,
        archived: archived,
        metadata: metadata
      ).call
    end

    def initialize(user:, feed_item_id:, read: nil, saved: nil, archived: nil, metadata: nil)
      @user = user
      @feed_item_id = feed_item_id
      @read = read
      @saved = saved
      @archived = archived
      @metadata = metadata
    end

    def call
      item = FeedItem.visible.find_by(id: @feed_item_id)
      raise NotFoundError, "Feed item not found" unless item

      existing = UserItem.find_by(user_id: @user.id, feed_item_id: item.id)
      unless existing || UserFeedSubscription.active.exists?(user_id: @user.id, feed_id: item.feed_id)
        raise ForbiddenError, "User is not subscribed to this item's feed"
      end

      now = Time.current
      user_item = existing || find_or_create_user_item!(item)

      updates = {}
      unless @read.nil?
        updates[:read_at] = @read ? (user_item.read_at || now) : nil
      end
      unless @saved.nil?
        updates[:saved_at] = @saved ? (user_item.saved_at || now) : nil
      end
      unless @archived.nil?
        updates[:archived_at] = @archived ? (user_item.archived_at || now) : nil
      end
      if @metadata.is_a?(Hash)
        updates[:metadata] = (user_item.metadata || {}).merge(@metadata.stringify_keys)
      end

      user_item.update!(updates) if updates.any?
      user_item
    end

    private

    def find_or_create_user_item!(item)
      ActiveRecord::Base.transaction(requires_new: true) do
        UserItem.create!(user: @user, feed_item: item)
      end
    rescue ActiveRecord::RecordNotUnique
      UserItem.find_by!(user_id: @user.id, feed_item_id: item.id)
    end
  end
end
