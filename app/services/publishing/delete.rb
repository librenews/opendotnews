module Publishing
  class Delete
    Result = Data.define(:document, :deleted)

    def self.call(user:, path:, expected_revision: nil, actor_type: "user", scope: "documents:write")
      new(user: user, actor_type: actor_type, scope: scope).call(path: path, expected_revision: expected_revision)
    end

    def initialize(user:, actor_type: "user", scope: "documents:write")
      @user = user
      @publication = user.default_publication
      @actor_type = actor_type
      @scope = scope
    end

    def call(path:, expected_revision: nil)
      norm_path = Publishing::PathNormalizer.normalize!(path)
      now = Time.current
      doc = nil

      ActiveRecord::Base.transaction do
        doc = Document.live.lock.find_by(publication_id: @publication.id, path: norm_path)
        raise Publishing::CreateOrRevise::NotFoundError, "Document '#{norm_path}' not found" unless doc

        if expected_revision.present? && expected_revision.to_i != doc.current_revision_number
          raise Publishing::CreateOrRevise::RevisionConflictError.new(
            "Revision conflict: expected #{expected_revision}, current is #{doc.current_revision_number}",
            current_revision: doc.current_revision_number
          )
        end

        was_public = doc.public?
        # Soft-delete tombstone preserves [publication_id, path] so deleted URLs are never recycled.
        doc.update!(deleted_at: now, visibility: "draft")

        ActiveRecord::Base.transaction(requires_new: true) do
          OutboxEvent.create!(
            event_type: "document.deleted",
            aggregate_type: "Document",
            aggregate_id: doc.id,
            aggregate_version: doc.current_revision_number,
            payload: { "publication_id" => doc.publication_id, "document_id" => doc.id, "path" => doc.path },
            created_at: now
          )
        rescue ActiveRecord::RecordNotUnique
          nil
        end

        if was_public
          ActiveRecord::Base.transaction(requires_new: true) do
            OutboxEvent.create!(
              event_type: "publication.feed_changed",
              aggregate_type: "Document",
              aggregate_id: doc.id,
              aggregate_version: doc.current_revision_number + 1,
              payload: { "publication_id" => doc.publication_id, "namespace" => doc.namespace, "document_id" => doc.id, "deleted" => true },
              created_at: now
            )
          rescue ActiveRecord::RecordNotUnique
            nil
          end
        end
      end

      AuditLog.record!(
        action: "document.deleted",
        user: @user,
        actor_type: @actor_type,
        resource_type: "Document",
        resource_id: doc.id,
        scope: @scope,
        metadata: { path: doc.path }
      )

      Result.new(document: doc, deleted: true)
    rescue Publishing::PathNormalizer::InvalidPathError => e
      raise Publishing::CreateOrRevise::InvalidInputError, e.message
    end
  end
end
