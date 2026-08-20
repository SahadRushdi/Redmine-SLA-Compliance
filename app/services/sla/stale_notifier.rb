# frozen_string_literal: true

module Sla
  # Immediate stale-ticket delivery. Normal callers are targeted stale_at jobs; the plural method
  # remains only as a compatibility facade for the explicit maintenance sweep.
  class StaleNotifier
    def enqueue_stale(issue, setting:, log:)
      return false unless log.queue!

      SlaEmailDeliveryJob.perform_later('stale_alert', issue.project_id, [log.id], setting.id)
      true
    rescue StandardError => e
      log.failed!(e)
      Rails.logger.error("[SLA] stale email enqueue failed for issue ##{issue.id}: #{e.class}: #{e.message}")
      false
    end

    # @param project [Project]
    def enqueue_stale_digest(project, logs, setting:)
      logs.count { |entry| enqueue_stale(entry.issue, setting: setting, log: entry) }
    end
  end
end
