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
    def enqueue_at_risk(issue, result)
      Rails.logger.info(
        "[SLA] at-risk notification queued for issue ##{issue.id} (breach_at=#{result.breach_at})"
      )
    end
  end
end
