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
  #     (issue_id, notification_type, target, cycle_key); only one caller anywhere can ever win a
  #     given at-risk episode (see #queue_at_risk for what an episode is).
  #   * stale digest — `SlaNotificationSetting.claim_stale_digest_window!` is an atomic
  #     conditional UPDATE keyed on the project's `last_stale_digest_at`; only one caller can win
  #     a given project's digest window, and it naturally re-opens once the configured frequency
  #     interval has elapsed.
  #
  # Nothing domain-specific is hard-coded: "open" means not in one of the policy's own configured
  # `resolved`-role statuses (see #open_issues), projects are those with the SLA module enabled and
  # an enabled effective policy, and all tracker/priority/status handling flows through the engine
  # via `PolicyContext`.
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

        open_issues(project, context).find_each do |issue|
          outcome = ResultStore.recalculate(issue, context: context, now: @now)
          swept += 1

          if outcome.newly_at_risk?
            newly += 1
            queued += 1 if queue_at_risk(issue, outcome)
          elsif track_stale && excluded_not_tracked?(outcome.record)
            stale_candidates << issue if stale?(issue, notification_setting.stale_threshold_days)
          end
        end

        stale_queued += queue_stale_digest(project, stale_candidates) if track_stale
      end

      Summary.new(swept: swept, newly_at_risk: newly, queued: queued, stale_queued: stale_queued)
    end

    private

    # Queue the at-risk notification exactly once PER AT-RISK EPISODE. `claim!` is an atomic
    # DB-level guard (a real unique index, not a check-then-act query), so this is safe even when
    # multiple app-server processes run their own copy of the sweep concurrently — only one of
    # them will ever get `true` back for a given claim.
    #
    # What identifies an episode is the engine's `at_risk_target` + `at_risk_since` (see
    # Sla::ResultClassifier::Result), which generalises the previous key in two steps:
    #   * per TARGET, the plan's Step 8.2 wording ("send once per ticket+target") — a ticket at risk
    #     on Response and later on Resolution has two things to say, not one;
    #   * per EPISODE rather than per measurement cycle. For the three one-shot targets these are the
    #     same thing (`at_risk_since` is the clock start, exactly the old key, and a reopen still
    #     yields a fresh one). Update Frequency is recurring: quiet → warned → updated → quiet again
    #     is ONE cycle but two real warnings, and keying on the cycle would have claimed the slot on
    #     the first silence and suppressed every later one for the life of that cycle.
    # Falls back to the ticket-level key if the engine reported no target, so a result predating
    # these fields still de-dupes rather than notifying on every sweep.
    def queue_at_risk(issue, outcome)
      result  = outcome.result
      target  = result&.at_risk_target.presence || SlaNotificationLog::NO_TARGET
      episode = result&.at_risk_since || result&.cycle_started_at

      return false unless SlaNotificationLog.claim!(
        issue_id: issue.id, notification_type: 'at_risk', target: target,
        cycle_key: episode&.to_i&.to_s || SlaNotificationLog::NO_CYCLE
      )

      @notifier.enqueue_at_risk(issue, outcome.record)
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

      # The window's own claimed instant is the cycle_key: a still-stale ticket gets a fresh key
      # every window (rather than being claimed once, ever), so it keeps reappearing in
      # subsequent digests for as long as it stays stale — the whole point of a recurring digest.
      window_key = setting.last_stale_digest_at.to_i.to_s
      claimed = stale_candidates.select do |issue|
        SlaNotificationLog.claim!(issue_id: issue.id, notification_type: 'stale', cycle_key: window_key)
      end
      @stale_notifier.enqueue_stale_digest(project, claimed) if claimed.any?
      claimed.size
    end

    # Active projects where the SLA module is enabled — mirrors the event-driven hook's gate so the
    # event-driven and time-driven paths cover exactly the same set of tickets.
    def swept_projects
      Project.active.has_module(:sla_compliance)
    end

    # The issues still worth re-evaluating: the OPEN ones, using the plugin's own definition of
    # open — not in a `resolved`-role status, the same milestone that stops the SLA clock and the
    # same population the dashboard's open-ticket cards count.
    #
    # Redmine's `Issue.open` is not equivalent and cannot be used here: a "Resolved" status is
    # commonly NOT is_closed (so `Issue.open` would keep re-sweeping tickets whose clock already
    # stopped), and conversely a status Redmine treats as closed but the policy never mapped to
    # `resolved` still has a running clock — under `Issue.open` those tickets would never be swept
    # again and their at-risk flag and breach_at would freeze at whatever the last event left.
    # Falls back to `Issue.open` only when the policy maps no resolved statuses at all.
    def open_issues(project, context)
      resolved_status_ids = Array(context.status_roles[:resolved])
      return project.issues.open if resolved_status_ids.empty?

      project.issues.where.not(status_id: resolved_status_ids)
    end
  end
end
