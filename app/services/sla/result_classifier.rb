# frozen_string_literal: true

module Sla
  # Phase 2 · Step 2.6 — Result classification.
  #
  # Produces an issue's SLA result: primary_state (met / breached / no_sla), the No-SLA sub-reason,
  # per-milestone elapsed seconds, deviation (breaches only), the at-risk flag, and projected
  # breach_at. This is the step that wires the engine together — timeline (2.1), the coverage
  # calculator (2.2/2.3), pauses (2.4), first-response (2.5), and at-risk (2.7).
  #
  # It emits a plain Result value object and performs NO database writes (the Phase 3 sweep is
  # responsible for persisting to sla_results). Inputs are already-resolved config so the whole
  # thing is unit-testable without a database.
  #
  # Milestones (each skipped when neither a numeric target nor Best Effort is set):
  #   * response   — clock start → first response (per policy.first_response_rule, 2.5)
  #   * workaround — clock start → first transition into a `work_started`-role status
  #   * resolution — clock start → first transition into a `resolved`-role status
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
    Result = Struct.new(:primary_state, :no_sla_reason, :at_risk, :breach_at,
                        :response_seconds, :workaround_seconds, :resolution_seconds,
                        :deviation_seconds, :cycle_started_at, :resolved_at, keyword_init: true)

    # @param policy [#business_hours?, #business_calendar, #first_response_rule,
    #   #at_risk_threshold, #pause_enabled, nil] the effective SlaPolicy (nil ⇒ not configured).
    # @param definition [#response_seconds, #workaround_seconds, #resolution_seconds,
    #   #any_target?, nil] the SlaDefinition for this tracker×priority (nil ⇒ not tracked).
    # @param tracker_configured [Boolean] whether the tracker is under SLA at all.
    # @param status_roles [Hash] {created:, work_started:, resolved:, pause:} => [status_id, ...].
    # @param current_status_id [Integer, nil] the issue's status RIGHT NOW — see #closed_at rung 2.
    # @param fallback_resolved_at [Time, nil] the issue's own `closed_on` — see #closed_at rungs 2/3.
    def initialize(timeline:, policy:, definition:, tracker_configured:, status_roles:,
                   current_status_id: nil, fallback_resolved_at: nil, now: Time.current)
      @timeline             = timeline
      @policy               = policy
      @definition           = definition
      @tracker_configured   = tracker_configured
      @roles                = status_roles || {}
      @current_status_id    = current_status_id
      @fallback_resolved_at = fallback_resolved_at
      @now                  = now
    end

    def classify
      return no_sla('not_configured') if @policy.nil? || !@tracker_configured
      return no_sla('not_tracked')    if @definition.nil? || !@definition.any_target?

      milestones = evaluated_milestones
      breached   = milestones.any? { |m| m[:breached] }
      primary    = breached ? 'breached' : 'met'
      at_risk, breach_at = risk(primary, milestones)

      Result.new(
        primary_state:      primary,
        no_sla_reason:      nil,
        at_risk:            at_risk,
        breach_at:          breach_at,
        response_seconds:   elapsed_for(milestones, :response),
        workaround_seconds: elapsed_for(milestones, :workaround),
        resolution_seconds: elapsed_for(milestones, :resolution),
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
        milestone(:resolution, @definition.resolution_seconds, resolution_at, @definition.resolution_best_effort?)
      ].compact
    end

    # A Best Effort milestone (target nil, best_effort true) is still evaluated — it has an
    # elapsed time worth reporting — but by definition NEVER breaches and is therefore never
    # at-risk either (there is no deadline to approach). A milestone that is neither targeted nor
    # Best Effort is skipped entirely, exactly as before.
    def milestone(kind, target, achieved_at, best_effort)
      return nil if target.nil? && !best_effort

      end_time = achieved_at || closed_at || @now
      elapsed  = pause.net_elapsed(clock_start, end_time)
      { kind: kind, target: target, elapsed: elapsed,
        breached: best_effort ? false : elapsed > target,
        pending: achieved_at.nil? && open?, best_effort: best_effort }
    end

    def risk(primary, milestones)
      return [false, nil] unless primary == 'met' && open?

      pending = milestones.select { |m| m[:pending] && !m[:best_effort] }
      return [false, nil] if pending.empty?

      AtRiskEvaluator.new(threshold_percent: @policy.at_risk_threshold,
                          calculator: calculator, now: @now).evaluate(pending)
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

    def workaround_at
      first_transition_into(role(:work_started))
    end

    def resolution_at
      first_transition_into(role(:resolved))
    end

    # When this ticket stopped being OPEN. "Open" means not resolved — the plugin's own configured
    # `resolved`-role statuses, the same milestone that stops the SLA clock, not Redmine's
    # is_closed flag (a "Resolved" status is commonly not is_closed).
    #
    # A journal transition is the accurate answer but is not always available, so this walks an
    # explicit ladder:
    #   1. the first transition into a `resolved`-role status after the clock started — the normal
    #      case, and the only one that gives a true resolution instant;
    #   2. otherwise, if the ticket is SITTING in a resolved-role status right now with no such
    #      transition recorded (created directly in it, imported, or resolved before the status was
    #      mapped to the role), fall back to Redmine's own `closed_on`, and failing that to the last
    #      recorded activity — a stable timestamp, unlike `now`, which would drift on every sweep;
    #   3. otherwise, when NO resolved-role statuses are configured at all (no policy — the
    #      `not_configured` case), fall back to Redmine's `closed_on` alone, so those tickets can
    #      still leave the open population.
    def closed_at
      return @closed_at if defined?(@closed_at)

      resolved_ids = role(:resolved)
      @closed_at =
        if resolved_ids.empty?
          @fallback_resolved_at
        elsif (transition = first_transition_into(resolved_ids))
          transition
        elsif resolved_ids.include?(@current_status_id)
          @fallback_resolved_at || @timeline.last_event_at || @now
        end
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

    def pause
      @pause ||= PauseCalculator.new(
        @timeline,
        pause_status_ids: (@policy.pause_enabled ? role(:pause) : []),
        calculator: calculator
      )
    end

    def calculator
      @calculator ||=
        if @policy.business_hours?
          BusinessHoursCalculator.new(@policy.business_calendar, zone: Time.zone)
        else
          CalendarTimeCalculator.new
        end
    end

    def role(name)
      Array(@roles[name])
    end
  end
end
