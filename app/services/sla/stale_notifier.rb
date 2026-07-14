# frozen_string_literal: true

module Sla
  # The sweep detects a project's stale-digest window coming due and hands the qualifying tickets
  # here to be queued. Phase 8 (Email Notifications) replaces this body with the real digest
  # mailer; keeping it a small injectable object lets the sweep's scheduling behavior be fully
  # tested without any mail infrastructure yet — mirrors `AtRiskNotifier`.
  class StaleNotifier
    # @param project [Project]
    # @param issues  [Array<Issue>] open, no_sla/not_tracked issues stale past the project's
    #   configured threshold
    def enqueue_stale_digest(project, issues)
      Rails.logger.info(
        "[SLA] stale-ticket digest queued for project ##{project.id} (#{issues.size} ticket(s))"
      )
    end
  end
end
