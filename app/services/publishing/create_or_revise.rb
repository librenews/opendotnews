require "digest"

module Publishing
  class CreateOrRevise
    class Error < StandardError; end
    class InvalidInputError < Error; end
    class PayloadTooLargeError < Error; end
    class PathConflictError < Error; end
    class NotFoundError < Error; end
    class IdempotencyConflictError < Error; end

    class RevisionConflictError < Error
      attr_reader :current_revision

      def initialize(message, current_revision:)
        super(message)
        @current_revision = current_revision
      end
    end

    Result = Data.define(:document, :revision, :created, :revised, :idempotent_replay)

    def self.create(user:, path:, markdown:, title: nil, visibility: nil, idempotency_key: nil, actor_type: "user", scope: "documents:write")
      new(user: user, actor_type: actor_type, scope: scope).create(
        path: path,
        markdown: markdown,
        title: title,
        visibility: visibility,
        idempotency_key: idempotency_key
      )
    end

    def self.update(user:, path:, markdown: nil, title: nil, visibility: nil, expected_revision: nil, idempotency_key: nil, actor_type: "user", scope: "documents:write")
      new(user: user, actor_type: actor_type, scope: scope).update(
        path: path,
        markdown: markdown,
        title: title,
        visibility: visibility,
        expected_revision: expected_revision,
        idempotency_key: idempotency_key
      )
    end

    def initialize(user:, actor_type: "user", scope: "documents:write")
      @user = user
      @publication = user.default_publication
      @actor_type = actor_type
      @scope = scope
    end

    def create(path:, markdown:, title: nil, visibility: nil, idempotency_key: nil)
      norm_path = normalize_path!(path)
      md = validate_markdown!(markdown)
      # Default strictly to draft so agents never accidentally expose private context.
      vis = validate_visibility!(visibility.presence || "draft")

      req_hash = Digest::SHA256.hexdigest([ "create", norm_path, title.to_s, vis, md ].join("\0"))
      if idempotency_key.present?
        replay = check_idempotency("publish_document", idempotency_key, req_hash)
        return replay if replay
      end

      parsed = Publishing::Render.extract_frontmatter(md)
      resolved_title = Publishing::Render.derive_title(
        explicit_title: title,
        frontmatter: parsed.frontmatter,
        body: parsed.body,
        path: norm_path
      )
      sha = Digest::SHA256.hexdigest(md)
      now = Time.current

      doc = nil
      rev = nil

      ActiveRecord::Base.transaction do
        # Includes soft-deleted tombstones so deleted public URLs are never recycled.
        if Document.exists?(publication_id: @publication.id, path: norm_path)
          raise PathConflictError, "A document (or deleted tombstone) already exists at path '#{norm_path}'"
        end

        doc = Document.create!(
          publication: @publication,
          path: norm_path,
          title: resolved_title,
          current_revision_number: 1,
          visibility: vis,
          published_at: (vis == "public" ? now : nil),
          rss_guid: "urn:uuid:#{SecureRandom.uuid}",
          content_sha256: sha
        )

        rev = DocumentRevision.create!(
          document: doc,
          revision_number: 1,
          markdown: md,
          sha256: sha,
          created_by_user: @user,
          created_at: now
        )

        emit_outbox!("document.created", doc, 1, now)
        if vis == "public"
          emit_outbox!("document.published", doc, 1, now)
          emit_feed_changed!(doc, 1, now)
        end

        save_idempotency!("publish_document", idempotency_key, req_hash, doc, rev) if idempotency_key.present?
      end

      AuditLog.record!(
        action: "document.created",
        user: @user,
        actor_type: @actor_type,
        resource_type: "Document",
        resource_id: doc.id,
        scope: @scope,
        metadata: { path: doc.path, visibility: doc.visibility, revision: 1 }
      )

      Result.new(document: doc, revision: rev, created: true, revised: true, idempotent_replay: false)
    rescue ActiveRecord::RecordNotUnique
      raise PathConflictError, "A document already exists at path '#{norm_path}'"
    end

    def update(path:, markdown: nil, title: nil, visibility: nil, expected_revision: nil, idempotency_key: nil)
      norm_path = normalize_path!(path)
      md = markdown.nil? ? nil : validate_markdown!(markdown)
      vis = visibility.nil? ? nil : validate_visibility!(visibility)

      req_hash = Digest::SHA256.hexdigest([ "update", norm_path, title.to_s, vis.to_s, expected_revision.to_s, md.to_s ].join("\0"))
      if idempotency_key.present?
        replay = check_idempotency("update_document", idempotency_key, req_hash)
        return replay if replay
      end

      doc = nil
      rev = nil
      revised = false
      now = Time.current

      ActiveRecord::Base.transaction do
        doc = Document.live.lock.find_by(publication_id: @publication.id, path: norm_path)
        raise NotFoundError, "Document '#{norm_path}' not found" unless doc

        if expected_revision.present? && expected_revision.to_i != doc.current_revision_number
          raise RevisionConflictError.new(
            "Revision conflict: expected #{expected_revision}, current is #{doc.current_revision_number}",
            current_revision: doc.current_revision_number
          )
        end

        was_public = doc.public?
        new_vis = vis || doc.visibility
        new_sha = md ? Digest::SHA256.hexdigest(md) : doc.content_sha256
        content_changed = md.present? && new_sha != doc.content_sha256

        new_title = if title.present?
          title.to_s.strip.truncate(255)
        elsif content_changed
          parsed = Publishing::Render.extract_frontmatter(md)
          parsed.frontmatter["title"].presence || doc.title
        else
          doc.title
        end

        next_rev_num = content_changed ? doc.current_revision_number + 1 : doc.current_revision_number
        published_at = doc.published_at
        published_at ||= now if new_vis == "public"

        doc.update!(
          title: new_title,
          visibility: new_vis,
          published_at: published_at,
          current_revision_number: next_rev_num,
          content_sha256: new_sha
        )

        if content_changed
          rev = DocumentRevision.create!(
            document: doc,
            revision_number: next_rev_num,
            markdown: md,
            sha256: new_sha,
            created_by_user: @user,
            created_at: now
          )
          revised = true
          emit_outbox!("document.updated", doc, next_rev_num, now)
        else
          rev = doc.current_revision
        end

        became_public = !was_public && new_vis == "public"
        became_draft = was_public && new_vis == "draft"
        public_changed = became_public || became_draft || (was_public && (content_changed || new_title != doc.title_before_last_save))

        if became_public
          emit_outbox!("document.published", doc, next_rev_num, now)
        elsif became_draft
          emit_outbox!("document.unpublished", doc, next_rev_num, now)
        end

        if public_changed
          emit_feed_changed!(doc, next_rev_num, now)
        end

        save_idempotency!("update_document", idempotency_key, req_hash, doc, rev) if idempotency_key.present?
      end

      AuditLog.record!(
        action: "document.updated",
        user: @user,
        actor_type: @actor_type,
        resource_type: "Document",
        resource_id: doc.id,
        scope: @scope,
        metadata: { path: doc.path, visibility: doc.visibility, revision: doc.current_revision_number, revised: revised }
      )

      Result.new(document: doc, revision: rev, created: false, revised: revised, idempotent_replay: false)
    end

    private

    def normalize_path!(path)
      Publishing::PathNormalizer.normalize!(path)
    rescue Publishing::PathNormalizer::InvalidPathError => e
      raise InvalidInputError, e.message
    end

    def validate_markdown!(markdown)
      raise InvalidInputError, "markdown is required" if markdown.nil?

      str = markdown.to_s.dup.force_encoding("UTF-8")
      raise InvalidInputError, "markdown must be valid UTF-8" unless str.valid_encoding?
      if str.bytesize > OpenNews.config.document_max_bytes
        raise PayloadTooLargeError, "markdown exceeds maximum size of #{OpenNews.config.document_max_bytes} bytes"
      end
      str
    end

    def validate_visibility!(vis)
      v = vis.to_s.strip.downcase
      unless %w[draft public].include?(v)
        raise InvalidInputError, "visibility must be 'draft' or 'public'"
      end
      v
    end

    def check_idempotency(operation, key, req_hash)
      rec = IdempotencyKey.find_by(user_id: @user.id, operation: operation, client_key: key.to_s)
      return nil unless rec && rec.expires_at > Time.current

      if rec.request_hash != req_hash
        raise IdempotencyConflictError, "Idempotency key '#{key}' was already used with different parameters"
      end

      doc = Document.find_by(id: rec.result_reference["document_id"])
      return nil unless doc

      rev = doc.revision(rec.result_reference["revision_number"]) || doc.current_revision
      Result.new(document: doc, revision: rev, created: false, revised: false, idempotent_replay: true)
    end

    def save_idempotency!(operation, key, req_hash, doc, rev)
      IdempotencyKey.upsert(
        {
          user_id: @user.id,
          operation: operation,
          client_key: key.to_s.truncate(255),
          request_hash: req_hash,
          result_reference: { "document_id" => doc.id, "revision_number" => rev.revision_number },
          expires_at: 24.hours.from_now,
          created_at: Time.current,
          updated_at: Time.current
        },
        unique_by: %i[user_id operation client_key]
      )
    end

    def emit_outbox!(event_type, doc, version, now)
      ActiveRecord::Base.transaction(requires_new: true) do
        OutboxEvent.create!(
          event_type: event_type,
          aggregate_type: "Document",
          aggregate_id: doc.id,
          aggregate_version: version,
          payload: {
            "publication_id" => doc.publication_id,
            "document_id" => doc.id,
            "path" => doc.path,
            "visibility" => doc.visibility,
            "revision_number" => version
          },
          created_at: now
        )
      rescue ActiveRecord::RecordNotUnique
        nil
      end
    end

    def emit_feed_changed!(doc, version, now)
      ActiveRecord::Base.transaction(requires_new: true) do
        OutboxEvent.create!(
          event_type: "publication.feed_changed",
          aggregate_type: "Document",
          aggregate_id: doc.id,
          aggregate_version: version,
          payload: {
            "publication_id" => doc.publication_id,
            "namespace" => doc.namespace,
            "document_id" => doc.id,
            "revision_number" => version
          },
          created_at: now
        )
      rescue ActiveRecord::RecordNotUnique
        nil
      end
    end
  end
end
