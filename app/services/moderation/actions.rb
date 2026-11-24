module Moderation
  # Operator moderation hooks for disabling abusive accounts and taking down public documents.
  module Actions
    module_function

    def disable_user!(target_user:, actor:, reason:)
      clean_reason = reason.to_s.strip.presence || "Policy violation"
      now = Time.current

      ActiveRecord::Base.transaction do
        target_user.disable!
        DownstreamSubscription
          .joins(:publication)
          .where(publications: { user_id: target_user.id }, status: %w[pending active])
          .update_all(status: "suspended", last_error: "Owner account disabled", updated_at: now)
      end

      AuditLog.record!(
        action: "moderation.user_disabled",
        user: actor,
        actor_type: "operator",
        resource_type: "User",
        resource_id: target_user.id,
        metadata: { target_namespace: target_user.namespace, reason: clean_reason }
      )
      target_user
    end

    def takedown_document!(document:, actor:, reason:)
      clean_reason = reason.to_s.strip.presence || "Moderation takedown"
      now = Time.current

      ActiveRecord::Base.transaction do
        was_public = document.public?
        document.update!(
          moderated_at: now,
          moderation_reason: clean_reason,
          visibility: "draft"
        )

        if was_public
          ActiveRecord::Base.transaction(requires_new: true) do
            OutboxEvent.create!(
              event_type: "publication.feed_changed",
              aggregate_type: "Document",
              aggregate_id: document.id,
              aggregate_version: document.current_revision_number + 1000,
              payload: {
                "publication_id" => document.publication_id,
                "namespace" => document.namespace,
                "document_id" => document.id,
                "moderated" => true
              },
              created_at: now
            )
          rescue ActiveRecord::RecordNotUnique
            nil
          end
        end
      end

      AuditLog.record!(
        action: "moderation.document_takedown",
        user: actor,
        actor_type: "operator",
        resource_type: "Document",
        resource_id: document.id,
        metadata: { path: document.path, namespace: document.namespace, reason: clean_reason }
      )
      document
    end
  end
end
