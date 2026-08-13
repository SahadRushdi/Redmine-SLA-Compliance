# frozen_string_literal: true

module Sla
  # The sweep detects when an open ticket crosses its at-risk threshold and hands it here to be
  # queued. Phase 8 (Email Notifications) replaces this body with the real mailer / digest
  # accumulation; keeping it a small injectable object lets the sweep be fully tested for the
  # "queued exactly once" guarantee without any mail infrastructure yet.
  #
  # It is deliberately side-effect-light: the sweep has already written the dedup row in
  # `sla_notification_logs`, so this only performs the actual outbound work (here, a log line).
  class AtRiskNotifier
    # @param issue  [Issue]
    # @param result [SlaResult] the freshly cached result (carries breach_at)
    def enqueue_at_risk(issue, result, setting:, log:)
      return false unless log.queue!

      SlaEmailDeliveryJob.perform_later('at_risk_realtime', issue.project_id, [log.id], setting.id)
      true
    rescue StandardError => e
      log.failed!(e)
      Rails.logger.error("[SLA] at-risk email enqueue failed for issue ##{issue.id}: #{e.class}: #{e.message}")
      false
    end
  end
end
