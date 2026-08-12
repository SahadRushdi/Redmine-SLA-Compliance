# frozen_string_literal: true

module Sla
  # Phase 2 · Step 2.6 — Result classification.
  #
  # Produces an issue's SLA result: primary_state (met / breached / no_sla), the No-SLA sub-reason,
  # per-milestone elapsed seconds, deviation (breaches only), the at-risk flag, and projected
  # breach_at. This is the step that wires the engine together — timeline (2.1), the coverage
  # calculator (2.2/2.3), first-response (2.5), and at-risk (2.7).
  #
  # It emits a plain Result value object and performs NO database writes (the Phase 3 sweep is
  # responsible for persisting to sla_results). Inputs are already-resolved config so the whole
  # thing is unit-testable without a database.
  #
  # Milestones (each skipped when neither a numeric target nor Best Effort is set):
  #   * response         — clock start → first response (per policy.first_response_rule, 2.5)
  #   * workaround       — clock start → first transition into a `work_started`-role status
  #   * resolution       — clock start → the instant the ticket became resolved (#closed_at, which
  #     means SITTING in a `resolved`-role status, not merely having once entered one)
  #   * update_frequency — the longest quiet gap between human status comments (Sla::UpdateFrequency-
  #     Evaluator). A recurring cadence rather than a one-shot event, but a target of EQUAL standing:
  #     breaching it makes the ticket `breached` exactly as breaching Resolution does, and it is
  #     at-risk-evaluated on the same threshold.
  # A Best Effort milestone (B4) has no numeric target — it never breaches and is never at-risk,
  # but its elapsed time is still tracked and reported.
  #
  # Clock: starts at creation and RESTARTS from the latest reopen (transition into a
  # `created`-role status). A resolved ticket stops the clock at resolution; an unachieved
  # milestone on a resolved ticket is judged by whether its target was exceeded by that point.
  class ResultClassifier
    # cycle_started_at — the same `clock_start` this classification measured milestones from
    # (creation, or the latest reopen). Exposed so the sweep can key at-risk notification dedup
    # per measurement cycle rather than per issue for life: a reopened ticket gets a new
    # clock_start, and so must be eligible for a fresh at-risk notification. nil for no_sla
    # results, which never reach the at-risk path.
    # at_risk_target / at_risk_since — WHICH target is at risk, and when the at-risk episode's own
    # clock started. Together they are the notification dedup key (Sla::Sweep#queue_at_risk): the
    # plan's "send once per ticket+target" (Step 8.2), and for Update Frequency once per SILENCE.
    # That target is recurring — quiet → warned → updated → quiet again is one measurement cycle but
    # two genuine warnings — so `cycle_started_at` alone would claim the slot on the first silence
    # and suppress every later one for the life of the cycle. `at_risk_since` is the clock start for
    # the three one-shot targets (identical to the old key) and the current gap's start for
    # Update Frequency. Both nil when the ticket is not at risk.
    Result = Struct.new(:primary_state, :no_sla_reason, :at_risk, :at_risk_at, :breach_at,
                        :at_risk_target, :at_risk_since,
                        :response_seconds, :workaround_seconds, :resolution_seconds,
                        :update_frequency_seconds, :deviation_seconds, :cycle_started_at,
                        :resolved_at, keyword_init: true)

    # @param policy [#first_response_rule, #at_risk_threshold, nil] the effective SlaPolicy
    #   (nil ⇒ not configured).
    # @param definition [#response_seconds, #workaround_seconds, #resolution_seconds,
    #   #any_target?, nil] the SlaDefinition for this tracker×priority (nil ⇒ not tracked).
    # @param tracker_configured [Boolean] whether the tracker is under SLA at all.
    # @param status_roles [Hash] {created:, work_started:, resolved:} => [status_id, ...].
    # @param current_status_id [Integer, nil] the issue's status RIGHT NOW — see #closed_at rung 2.
    # @param fallback_resolved_at [Time, nil] the issue's own `closed_on` — see #closed_at rungs 2/3.
    # @param non_human_author_ids [Array<Integer>, #call] journal authors that are not a real person;
    #   only the Update Frequency target consults them (Sla::UpdateFrequencyEvaluator#human_author?).
    #   Pass a callable to defer the lookup until a cadence target actually needs it.
    def initialize(timeline:, policy:, definition:, tracker_configured:, status_roles:,
                   current_status_id: nil, fallback_resolved_at: nil, non_human_author_ids: [],
                   now: Time.current)
      @timeline             = timeline
      @policy               = policy
      @definition           = definition
      @tracker_configured   = tracker_configured
      @roles                = status_roles || {}
      @current_status_id    = current_status_id
      @fallback_resolved_at = fallback_resolved_at
      @non_human_author_ids = non_human_author_ids
      @now                  = now
    end

    def classify
      return no_sla('not_configured') if @policy.nil? || !@tracker_configured
      return no_sla('not_tracked')    if @definition.nil? || !@definition.any_target?

      milestones = evaluated_milestones
      breached   = milestones.any? { |m| m[:breached] }
      primary    = breached ? 'breached' : 'met'
      at_risk, breach_at, at_risk_kind, at_risk_at = risk(primary, milestones)

      Result.new(
        primary_state:      primary,
        no_sla_reason:      nil,
        at_risk:            at_risk,
        at_risk_at:         at_risk_at,
        breach_at:          breach_at,
        at_risk_target:     at_risk_kind&.to_s,
        at_risk_since:      at_risk_kind && risk_since(milestones, at_risk_kind),
        response_seconds:   elapsed_for(milestones, :response),
        workaround_seconds: elapsed_for(milestones, :workaround),
        resolution_seconds: elapsed_for(milestones, :resolution),
        # The longest quiet gap, not a span from the clock start — see #update_frequency_milestone.
        update_frequency_seconds: elapsed_for(milestones, :update_frequency),
        deviation_seconds:  breached ? max_overage(milestones) : nil,
        cycle_started_at:   clock_start,
        resolved_at:        closed_at
      )
    end

    private

    # `resolved_at` is set here too, even though a No-SLA ticket has nothing to measure: the
    # dashboard's definition of an OPEN ticket is `sla_results.resolved_at IS NULL`, and the No SLA
    # card counts open tickets. Leaving it nil would park every No-SLA ticket ever created in the
    # open population for life. `cycle_started_at` stays nil — No SLA never reaches the at-risk
    # path that consumes it (see the Result comment above).
    def no_sla(reason)
      Result.new(primary_state: 'no_sla', no_sla_reason: reason, at_risk: false,
                 resolved_at: closed_at)
    end

    def evaluated_milestones
      [
        milestone(:response,   @definition.response_seconds,   response_at,   @definition.response_best_effort?),
        milestone(:workaround, @definition.workaround_seconds, workaround_at, @definition.workaround_best_effort?),
        # The Resolution milestone is achieved at exactly the instant the ticket stopped being open
        # — one rule, `closed_at`, not a second "first transition into a resolved status" that could
        # disagree with it. Without this a ticket that came back out of a resolved status would
        # reappear in the open population still carrying a permanently-satisfied Resolution target
        # that could never breach again.
        milestone(:resolution, @definition.resolution_seconds, closed_at, @definition.resolution_best_effort?),
        update_frequency_milestone
      ].compact
    end

    # Update Frequency joins the three above as an equal — same skip rule (no target and not Best
    # Effort ⇒ not evaluated), same breach consequence, same at-risk treatment — but it cannot use
    # #milestone, because it is not a span from the clock start to one event:
    #
    #   * `elapsed` is the LARGEST quiet gap so far, which is what a breach is judged on and what
    #     the deviation is measured from. It is not monotonic in the way the other three are: a
    #     ticket that goes quiet, is updated, then goes quiet again is re-judged on whichever
    #     silence was longest.
    #   * `risk_elapsed` is the gap running RIGHT NOW, which is what the at-risk warning must use.
    #     Feeding the max gap to the at-risk check would leave a ticket flagged "about to breach"
    #     forever after one long-but-recovered silence, even seconds after a fresh update.
    #   * `pending` is simply "still open": the cadence clock never stops running while it is, so
    #     there is no achieved-at instant to compare against.
    def update_frequency_milestone
      target      = @definition.update_frequency_seconds
      best_effort = @definition.update_frequency_best_effort?
      return nil if target.nil? && !best_effort

      gaps = UpdateFrequencyEvaluator.new(
        @timeline, target_seconds: target, calculator: calculator, from: clock_start,
        to: closed_at || @now, non_human_author_ids: non_human_author_ids
      ).evaluate

      { kind: :update_frequency, target: target, elapsed: gaps.max_gap_seconds,
        risk_elapsed: gaps.current_gap_seconds, risk_since: gaps.current_gap_started_at,
        breached: best_effort ? false : gaps.breached?,
        pending: open?, best_effort: best_effort }
    end

    # Resolved on FIRST USE, and only from here — the sole consumer. Accepts either the ids or a
    # callable that produces them, which is what `IssueEvaluator` passes: the lookup is a query, and
    # an issue whose priority has no cadence target (the common case, and every issue in a project
    # that uses none) returns above without ever paying it. Global Rule 4 — don't slow issue saves.
    def non_human_author_ids
      @resolved_non_human_author_ids ||=
        Array(@non_human_author_ids.respond_to?(:call) ? @non_human_author_ids.call : @non_human_author_ids)
    end

    # A Best Effort milestone (target nil, best_effort true) is still evaluated — it has an
    # elapsed time worth reporting — but by definition NEVER breaches and is therefore never
    # at-risk either (there is no deadline to approach). A milestone that is neither targeted nor
    # Best Effort is skipped entirely, exactly as before.
    def milestone(kind, target, achieved_at, best_effort)
      return nil if target.nil? && !best_effort

      end_time = achieved_at || closed_at || @now
      elapsed  = calculator.elapsed(clock_start, end_time)
      { kind: kind, target: target, elapsed: elapsed,
        breached: best_effort ? false : elapsed > target,
        pending: achieved_at.nil? && open?, best_effort: best_effort }
    end

    def risk(primary, milestones)
      return [false, nil, nil, nil] unless primary == 'met' && open?

      pending = milestones.select { |m| m[:pending] && !m[:best_effort] }
      return [false, nil, nil, nil] if pending.empty?

      AtRiskEvaluator.new(threshold_percent: @policy.at_risk_threshold,
                          calculator: calculator, now: @now).evaluate(pending.map { |m| risk_input(m) })
    end

    # What the at-risk check measures for a milestone. For the three one-shot milestones that is
    # just their elapsed time; Update Frequency supplies its own (`risk_elapsed` — the gap running
    # now rather than the longest one ever seen). See #update_frequency_milestone.
    def risk_input(milestone)
      { kind: milestone[:kind], target: milestone[:target],
        elapsed: milestone[:risk_elapsed] || milestone[:elapsed] }
    end

    # When the at-risk episode being reported began — the dedup key's second half (see Result).
    # The clock start for a one-shot milestone, whose at-risk window opens once per cycle and never
    # reopens; the running gap's start for Update Frequency, which opens a new one per silence.
    def risk_since(milestones, kind)
      milestone = milestones.find { |m| m[:kind] == kind }
      (milestone && milestone[:risk_since]) || clock_start
    end

    def elapsed_for(milestones, kind)
      milestone = milestones.find { |m| m[:kind] == kind }
      milestone && milestone[:elapsed]
    end

    def max_overage(milestones)
      milestones.select { |m| m[:breached] }.map { |m| m[:elapsed] - m[:target] }.max
    end

    def response_at
      FirstResponseDetector.new(@timeline, rule: @policy.first_response_rule)
                           .detect(since: clock_start)
    end

    # Work genuinely starts once. Unlike resolution (below), re-entering a `work_started` status
    # does not un-start it, so the FIRST transition is the right answer here and stays that way.
    def workaround_at
      first_transition_into(role(:work_started))
    end

    # When this ticket stopped being OPEN. "Open" means not resolved — the plugin's own configured
    # `resolved`-role statuses, the same milestone that stops the SLA clock, not Redmine's
    # is_closed flag (a "Resolved" status is commonly not is_closed).
    #
    # RESOLVED MEANS *CURRENTLY* RESOLVED (Step 6A.6). This used to take the first transition into a
    # resolved-role status and treat it as final, which was wrong the moment a ticket came back out.
    # "Waiting on Client" is a resolved-role status on a typical policy, so `New → Waiting on Client
    # → In progress` recorded a ticket as resolved two hours after creation and left it that way
    # while it was actively being worked — gone from every open-ticket figure, with an understated
    # resolution time, counted in the SLA Met percentage for a period it had not resolved in. It was
    # masked only where the workflow happened to route returns through a `created`-role status,
    # which restarts `clock_start` and self-heals the row by accident, not by design.
    #
    # A journal transition is the accurate answer but is not always available, so this walks an
    # explicit ladder:
    #   1. the ticket is NOT in a resolved-role status right now ⇒ nil, it is open. This is the test
    #      that makes leaving the resolved set restart the clock, and it matches what
    #      `Sla::Sweep#open_issues` has always selected on;
    #   2. it IS in one ⇒ the first transition of the CURRENT unbroken resolved run. Moving between
    #      two resolved statuses (Waiting on Client → Closed) neither restarts nor advances the
    #      instant: the clock stopped when the ticket stopped consuming SLA time, which is the entry
    #      into the set, not the last hop inside it;
    #   3. it IS in one but no transition bounds that run (created directly in it, imported, or
    #      resolved before the status was mapped to the role) ⇒ Redmine's own `closed_on`, failing
    #      that the last recorded activity — a stable timestamp, unlike `now`, which would drift on
    #      every sweep;
    #   4. NO resolved-role statuses are configured at all (no policy — the `not_configured` case)
    #      ⇒ Redmine's `closed_on` alone, so those tickets can still leave the open population.
    def closed_at
      return @closed_at if defined?(@closed_at)

      resolved_ids = role(:resolved)
      @closed_at =
        if resolved_ids.empty?
          @fallback_resolved_at
        elsif !resolved_ids.include?(current_status_id)
          nil
        else
          resolved_span_start(resolved_ids) ||
            @fallback_resolved_at || @timeline.last_event_at || @now
        end
    end

    # Where the ticket IS right now. The issue's live status wins when we have it — that is why
    # rung 3 exists at all, since the journal history can be missing the transition that put it
    # there — falling back to the last status the timeline recorded.
    def current_status_id
      @current_status_id || @timeline.status_intervals.last[:status_id]
    end

    # The first transition of the unbroken TRAILING run of resolved-role statuses: walk the
    # transitions backwards while they keep landing in the resolved set, and stop at the first that
    # does not.
    #
    # Anchored on a transition rather than on `status_intervals`' `started_at` deliberately: a
    # ticket created directly INTO a resolved status has a trailing run reaching back to its
    # creation event, and creation time is not a trustworthy resolution instant for it (rung 3's
    # `closed_on` is). Returning nil in that case, and when the run starts at or before the current
    # measurement cycle (a status mapped to both the created and resolved roles), hands those to the
    # rung-3 fallback rather than inventing an instant.
    def resolved_span_start(resolved_ids)
      span_start = nil
      @timeline.status_changes.sort_by(&:at).reverse_each do |change|
        break unless resolved_ids.include?(change.to_status_id)

        span_start = change.at
      end
      span_start if span_start && span_start > clock_start
    end

    def open?
      closed_at.nil?
    end

    def first_transition_into(status_ids)
      return nil if status_ids.empty?

      @timeline.status_changes
               .select { |c| status_ids.include?(c.to_status_id) && c.at > clock_start }
               .min_by(&:at)&.at
    end

    # Latest entry into a `created`-role status (a reopen), or creation if never reopened.
    def clock_start
      @clock_start ||= begin
        reopen = @timeline.status_changes
                          .select { |c| role(:created).include?(c.to_status_id) }
                          .map(&:at).max
        [reopen, @timeline.created_event&.at].compact.max
      end
    end

    def calculator
      @calculator ||= CalendarTimeCalculator.new
    end

    def role(name)
      Array(@roles[name])
    end
  end
end
