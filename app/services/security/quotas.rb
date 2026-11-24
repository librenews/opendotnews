module Security
  module Quotas
    class QuotaExceededError < StandardError
      attr_reader :quota_name

      def initialize(message, quota_name:)
        super(message)
        @quota_name = quota_name
      end
    end

    module_function

    def check_subscription_quota!(user)
      limit = OpenNews.config.max_subscriptions_per_user
      return if limit <= 0

      count = user.active_subscriptions.count
      if count >= limit
        raise QuotaExceededError.new(
          "Subscription quota exceeded (maximum #{limit} active feeds per account)",
          quota_name: "max_subscriptions_per_user"
        )
      end
    end

    def check_document_create_quota!(user, new_bytes:)
      pub = user.default_publication
      cfg = OpenNews.config

      if cfg.max_documents_per_user > 0
        live_count = pub.documents.live.count
        if live_count >= cfg.max_documents_per_user
          raise QuotaExceededError.new(
            "Document count quota exceeded (maximum #{cfg.max_documents_per_user} live documents per account)",
            quota_name: "max_documents_per_user"
          )
        end
      end

      check_document_storage_and_rate!(user, pub, new_bytes: new_bytes)
    end

    def check_document_update_quota!(user, new_bytes:)
      pub = user.default_publication
      check_document_storage_and_rate!(user, pub, new_bytes: new_bytes)
    end

    def check_downstream_subscriber_quota!(publication)
      limit = OpenNews.config.max_downstream_subscribers_per_publication
      return if limit <= 0

      active_count = publication.downstream_subscriptions.active.count
      if active_count >= limit
        raise QuotaExceededError.new(
          "Downstream subscriber quota exceeded (maximum #{limit} active subscribers per publication)",
          quota_name: "max_downstream_subscribers_per_publication"
        )
      end
    end

    def user_document_storage_bytes(publication)
      DocumentRevision
        .joins(:document)
        .where(documents: { publication_id: publication.id, deleted_at: nil })
        .sum("octet_length(document_revisions.markdown)")
        .to_i
    end

    def check_document_storage_and_rate!(user, pub, new_bytes:)
      cfg = OpenNews.config

      if cfg.max_document_storage_bytes_per_user > 0 && new_bytes.to_i > 0
        used = user_document_storage_bytes(pub)
        if used + new_bytes.to_i > cfg.max_document_storage_bytes_per_user
          raise QuotaExceededError.new(
            "Document storage quota exceeded (maximum #{cfg.max_document_storage_bytes_per_user} bytes per account)",
            quota_name: "max_document_storage_bytes_per_user"
          )
        end
      end

      if cfg.max_publishes_per_hour > 0
        recent = DocumentRevision
          .joins(:document)
          .where(documents: { publication_id: pub.id })
          .where("document_revisions.created_at >= ?", 1.hour.ago)
          .count
        if recent >= cfg.max_publishes_per_hour
          raise QuotaExceededError.new(
            "Publish rate quota exceeded (maximum #{cfg.max_publishes_per_hour} document revisions per hour)",
            quota_name: "max_publishes_per_hour"
          )
        end
      end
    end
  end
end
