module Accounts
  # Account erasure per Section 13.9:
  # - Revokes all sessions and OAuth tokens/grants
  # - Deletes all reader subscriptions, lazy UserItem state, inbox events, OPML imports, idempotency keys
  # - Removes all draft documents & revisions; converts previously published documents into 410 tombstones
  # - Unsubscribes downstream push listeners and anonymizes the disabled user record while keeping
  #   the namespace reserved so deleted publisher URLs cannot be hijacked.
  class Erase
    def self.call(user:, actor: nil, reason: "user_requested")
      new(user: user, actor: actor || user, reason: reason).call
    end

    def initialize(user:, actor:, reason:)
      @user = user
      @actor = actor
      @reason = reason.to_s.strip.presence || "user_requested"
    end

    def call
      now = Time.current
      affected_feed_ids = []

      ActiveRecord::Base.transaction do
        affected_feed_ids = @user.user_feed_subscriptions.pluck(:feed_id).uniq

        @user.sessions.delete_all
        Doorkeeper::AccessToken.where(resource_owner_id: @user.id).delete_all
        Doorkeeper::AccessGrant.where(resource_owner_id: @user.id).delete_all

        @user.user_inbox_events.delete_all
        @user.user_items.delete_all
        @user.user_feed_subscriptions.delete_all
        @user.opml_imports.delete_all
        @user.idempotency_keys.delete_all

        @user.publications.find_each do |pub|
          pub.downstream_subscriptions.update_all(
            status: "unsubscribed",
            secret: nil,
            last_error: "Publisher account erased",
            updated_at: now
          )

          pub.documents.find_each do |doc|
            if doc.published_at.present?
              # Keep tombstone row (deleted_at) so public URLs return 410 and cannot be hijacked;
              # wipe markdown body revisions for data erasure.
              doc.document_revisions.delete_all
              doc.update!(deleted_at: doc.deleted_at || now, visibility: "draft", title: "[deleted]")
            else
              doc.destroy!
            end
          end

          pub.update!(visibility: "private", description: nil)
        end

        @user.update!(
          email: "erased-#{@user.id}@erased.invalid",
          disabled_at: now,
          password: SecureRandom.hex(32)
        )
      end

      # Reconcile upstream push subscriptions for feeds that may now have zero active subscribers.
      affected_feed_ids.each do |fid|
        Push::RegisterUpstreamJob.perform_async(fid)
      end

      AuditLog.record!(
        action: "account.erased",
        user: (@actor.id == @user.id ? nil : @actor),
        actor_type: (@actor.id == @user.id ? "user" : "operator"),
        resource_type: "User",
        resource_id: @user.id,
        metadata: { namespace: @user.namespace, reason: @reason, feeds_unlinked: affected_feed_ids.size }
      )

      true
    end
  end
end
