# frozen_string_literal: true

module RedmineSlaCompliance
  module Patches
    # Event-driven recompute (Step 3.1) and Google Chat notification (Step 7.1).
    # Keeps the `sla_results` cache fresh whenever an issue changes, WITHOUT computing on page load,
    # and announces newly created SLA-covered issues to Google Chat. Applied to Redmine's Issue
    # model with the standard include-guard monkeypatch (Global Rule 4: no core file edits —
    # plugin/hook API only).
    #
    # Both callbacks run on `after_commit`, not `after_save`, for two reasons:
    #   * correctness — the journal written by this save is committed, so `TimelineBuilder` sees it,
    #     and the issue row is visible to the notification job's own connection;
    #   * safety — they execute off the save transaction and are each wrapped in a rescue, so a
    #     recompute or notification failure can never roll back or block the user's issue save
    #     (Global Rule 4).
    module IssuePatch
      def self.included(base)
        base.class_eval do
          after_commit :sla_recalculate_result, on: %i[create update]
          after_commit :sla_notify_google_chat, on: :create
        end
      end

      private

      # Recompute and cache this issue's SLA result. Scoped to projects where the SLA module is
      # enabled, so unrelated projects issue saves neither pay the cost nor bloat the cache.
      def sla_recalculate_result
        return unless project&.module_enabled?(:sla_compliance)

        Sla::ResultStore.recalculate(self)
      rescue StandardError => e
        Rails.logger.error("[SLA] result recompute failed for issue ##{id}: #{e.message}")
      end

      # Step 7.1 — hand a newly created issue to the notification job. Only the module gate runs
      # here: it is answered from Redmine's own cached enabled-modules, whereas the policy lookup
      # and the webhook read are queries, so they live in the job where they cost the user nothing.
      # The enqueue itself is rescued too — a queue adapter that refuses the job must not surface
      # as an error to whoever just saved the issue.
      def sla_notify_google_chat
        return unless project&.module_enabled?(:sla_compliance)

        SlaGoogleChatNotificationJob.perform_later(id)
      rescue StandardError => e
        Rails.logger.error("[SLA] Google Chat notification enqueue failed for issue ##{id}: #{e.message}")
      end
    end
  end
end
