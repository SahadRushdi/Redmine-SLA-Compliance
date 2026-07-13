# frozen_string_literal: true

module RedmineSlaCompliance
  module Patches
    # Event-driven recompute.
    # Keeps the `sla_results` cache fresh whenever an issue changes, WITHOUT computing on page load.
    # Applied to Redmine's Issue model with the standard include-guard monkeypatch (Global Rule 4:
    # no core file edits — plugin/hook API only).
    #
    # Runs on `after_commit`, not `after_save`, for two reasons:
    #   * correctness — the journal written by this save is committed, so `TimelineBuilder` sees it;
    #   * safety — it executes off the save transaction and is wrapped in a rescue, so a recompute
    #     failure can never roll back or block the user's issue save (Global Rule 4).
    module IssuePatch
      def self.included(base)
        base.class_eval do
          after_commit :sla_recalculate_result, on: %i[create update]
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
    end
  end
end
