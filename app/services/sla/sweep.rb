# frozen_string_literal: true

module Sla
  # Scheduled at-risk / stale sweep. The core time-driven piece.
  # Re-evaluates every OPEN, SLA-tracked ticket so at-risk / breach state advances with the clock
  # even when no ticket event fires, then queues a one-time notification for each ticket that has
  # just crossed its at-risk threshold — and separately drives each project's stale-ticket digest
  # schedule (Step 2.8's excluded-ticket detector, wired in here). Runs off the request path
  # (scheduler thread / rake task); the dashboard only ever reads the `sla_results` rows this
  # refreshes.
  #
  # Idempotency (the hard requirement): the sweep runs repeatedly, and may run concurrently in
  # more than one app-server process, and must NEVER double-send. Both notification paths rely on
  # a real DB constraint rather than an app-level check-then-act:
  #   * at-risk — `SlaNotificationLog.claim!` is guarded by a unique index on
  #     (issue_id, notification_type, target); only one caller anywhere can ever win it for a
  #     given issue.
  #   * stale digest — `SlaNotificationSetting.claim_stale_digest_window!` is an atomic
  #     conditional UPDATE keyed on the project's `last_stale_digest_at`; only one caller can win
  #     a given project's digest window, and it naturally re-opens once the configured frequency
  #     interval has elapsed.
  #
  # Nothing domain-specific is hard-coded: "open" is Redmine's own `Issue.open` (its `is_closed`
  # status config), projects are those with the SLA module enabled and an enabled effective policy,
  # and all tracker/priority/status handling flows through the engine via `PolicyContext`.
  class Sweep
    # swept          — issues recomputed
    # newly_at_risk  — issues that crossed the at-risk threshold this run
    # queued         — at-risk notifications actually enqueued this run
    # stale_queued   — tickets newly included in a stale-ticket digest this run
    Summary = Struct.new(:swept, :newly_at_risk, :queued, :stale_queued, keyword_init: true)

    def initialize(now: Time.current, notifier: AtRiskNotifier.new,
                   stale_notifier: StaleNotifier.new)
      @now            = now
      @notifier       = notifier
      @stale_notifier = stale_notifier
    end

    def run
      swept = newly = queued = stale_queued = 0

      swept_projects.each do |project|
        context = PolicyContext.for_project(project)
        next unless context.policy # only projects with an enabled effective policy

        notification_setting = SlaNotificationSetting.find_by(project_id: project.id)
        track_stale = notification_setting&.stale_email_enabled? || false
        stale_candidates = []

        open_issues(project).find_each do |issue|
          outcome = ResultStore.recalculate(issue, context: context, now: @now)
          swept += 1

          if outcome.newly_at_risk?
            newly += 1
            queued += 1 if queue_at_risk(issue, outcome.record)
          elsif track_stale && excluded_not_tracked?(outcome.record)
            stale_candidates << issue if stale?(issue, notification_setting.stale_threshold_days)
          end
        end

        stale_queued += queue_stale_digest(project, stale_candidates) if track_stale
      end

      Summary.new(swept: swept, newly_at_risk: newly, queued: queued, stale_queued: stale_queued)
    end

    private

    # Queue the at-risk notification exactly once. `claim!` is an atomic DB-level guard (a real
    # unique index, not a check-then-act query), so this is safe even when multiple app-server
    # processes run their own copy of the sweep concurrently — only one of them will ever get
    # `true` back for a given issue.
    def queue_at_risk(issue, result)
      return false unless SlaNotificationLog.claim!(issue_id: issue.id, notification_type: 'at_risk')

      @notifier.enqueue_at_risk(issue, result)
      true
    end

    # Step 2.8's exact scope: "unclassified priority or unset target" — both surface as
    # no_sla/not_tracked (never not_configured, which means the tracker isn't under SLA at all and
    # so has no "excluded ticket that needs triage" signal to report).
    def excluded_not_tracked?(result)
      result.primary_state == 'no_sla' && result.no_sla_reason == 'not_tracked'
    end

    def stale?(issue, threshold_days)
      timeline = TimelineBuilder.new(issue).build
      StaleTicketDetector.new(timeline, now: @now).stale?(threshold_days.days.to_i)
    end

    # Claim this project's stale-digest window and queue whichever candidates are still stale at
    # claim time. Called on every sweep tick while stale email is enabled — cheap no-op (0 rows
    # updated) until the project's configured frequency interval has actually elapsed, at which
    # point the schedule gate on `sla_notification_settings.last_stale_digest_at` advances. This
    # runs even with an empty candidate list so a project with zero stale tickets this period
    # still doesn't get re-checked every 15 minutes.
    def queue_stale_digest(project, stale_candidates)
      setting = SlaNotificationSetting.claim_stale_digest_window!(project.id, now: @now)
      return 0 unless setting

      claimed = stale_candidates.select do |issue|
        SlaNotificationLog.claim!(issue_id: issue.id, notification_type: 'stale')
      end
      @stale_notifier.enqueue_stale_digest(project, claimed) if claimed.any?
      claimed.size
    end

    # Active projects where the SLA module is enabled — mirrors the event-driven hook's gate so the
    # event-driven and time-driven paths cover exactly the same set of tickets.
    def swept_projects
      Project.active.has_module(:sla_compliance)
    end

    # Open (non-closed) issues in the project, using Redmine's own status configuration.
    def open_issues(project)
      project.issues.open
    end
  end
end
