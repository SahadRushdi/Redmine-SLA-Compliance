# frozen_string_literal: true

module Sla
  # Scheduled at-risk / stale sweep. The core time-driven piece.
  # Re-evaluates every OPEN, SLA-tracked ticket so at-risk / breach state advances with the clock
  # even when no ticket event fires, then queues a one-time notification for each ticket that has
  # just crossed its at-risk threshold. Runs off the request path (rufus scheduler thread / rake
  # task); the dashboard only ever reads the `sla_results` rows this refreshes.
  #
  # Idempotency (the hard requirement): the sweep runs repeatedly and must NEVER double-send.
  # Two independent guards ensure a ticket is queued exactly once:
  #   1. transition detection — `ResultStore::Outcome#newly_at_risk?` is true only on the single
  #      recompute where the cached flag goes false → true;
  #   2. the `sla_notification_logs` ledger — `already_sent?` blocks a second queue even if the
  #      transition were somehow re-observed (e.g. the cache row was rebuilt).
  #
  # Nothing domain-specific is hard-coded: "open" is Redmine's own `Issue.open` (its `is_closed`
  # status config), projects are those with the SLA module enabled and an enabled effective policy,
  # and all tracker/priority/status handling flows through the engine via `PolicyContext`.
  class Sweep
    # swept          — issues recomputed
    # newly_at_risk  — issues that crossed the threshold this run
    # queued         — at-risk notifications actually enqueued (== newly_at_risk minus any already
    #                  logged; equal to newly_at_risk in normal operation)
    Summary = Struct.new(:swept, :newly_at_risk, :queued, keyword_init: true)

    def initialize(now: Time.current, notifier: AtRiskNotifier.new)
      @now      = now
      @notifier = notifier
    end

    def run
      swept = newly = queued = 0

      swept_projects.each do |project|
        context = PolicyContext.for_project(project)
        next unless context.policy # only projects with an enabled effective policy

        open_issues(project).find_each do |issue|
          outcome = ResultStore.recalculate(issue, context: context, now: @now)
          swept += 1
          next unless outcome.newly_at_risk?

          newly += 1
          queued += 1 if queue_at_risk(issue, outcome.record)
        end
      end

      Summary.new(swept: swept, newly_at_risk: newly, queued: queued)
    end

    private

    # Queue the at-risk notification exactly once, guarded by the dedup ledger. Returns whether a
    # new notification was enqueued.
    def queue_at_risk(issue, result)
      return false if SlaNotificationLog.already_sent?(issue_id: issue.id,
                                                       notification_type: 'at_risk')

      SlaNotificationLog.create!(issue_id: issue.id, notification_type: 'at_risk',
                                 target: nil, sent_at: nil) # sent_at nil = queued, not yet delivered
      @notifier.enqueue_at_risk(issue, result)
      true
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
