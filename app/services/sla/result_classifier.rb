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
  # Milestones (each skipped when its target is nil):
  #   * response   — clock start → first response (per policy.first_response_rule, 2.5)
  #   * workaround — clock start → first transition into a `work_started`-role status
  #   * resolution — clock start → first transition into a `resolved`-role status
  #
  # Clock: starts at creation and RESTARTS from the latest reopen (transition into a
  # `created`-role status). A resolved ticket stops the clock at resolution; an unachieved
  # milestone on a resolved ticket is judged by whether its target was exceeded by that point.
  class ResultClassifier
    Result = Struct.new(:primary_state, :no_sla_reason, :at_risk, :breach_at,
                        :response_seconds, :workaround_seconds, :resolution_seconds,
                        :deviation_seconds, keyword_init: true)

    # @param policy [#business_hours?, #business_calendar, #first_response_rule,
    #   #at_risk_threshold, #pause_enabled, nil] the effective SlaPolicy (nil ⇒ not configured).
    # @param definition [#response_seconds, #workaround_seconds, #resolution_seconds,
    #   #any_target?, nil] the SlaDefinition for this tracker×priority (nil ⇒ not tracked).
    # @param tracker_configured [Boolean] whether the tracker is under SLA at all.
    # @param status_roles [Hash] {created:, work_started:, resolved:, pause:} => [status_id, ...].
    def initialize(timeline:, policy:, definition:, tracker_configured:, status_roles:,
                   now: Time.current)
      @timeline           = timeline
      @policy             = policy
      @definition         = definition
      @tracker_configured = tracker_configured
      @roles              = status_roles || {}
      @now                = now
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
        deviation_seconds:  breached ? max_overage(milestones) : nil
      )
    end

    private

    def no_sla(reason)
      Result.new(primary_state: 'no_sla', no_sla_reason: reason, at_risk: false)
    end

    def evaluated_milestones
      [
        milestone(:response,   @definition.response_seconds,   response_at),
        milestone(:workaround, @definition.workaround_seconds, workaround_at),
        milestone(:resolution, @definition.resolution_seconds, resolution_at)
      ].compact
    end

    def milestone(kind, target, achieved_at)
      return nil if target.nil?

      end_time = achieved_at || closed_at || @now
      elapsed  = pause.net_elapsed(clock_start, end_time)
      { kind: kind, target: target, elapsed: elapsed,
        breached: elapsed > target, pending: achieved_at.nil? && open? }
    end

    def risk(primary, milestones)
      return [false, nil] unless primary == 'met' && open?

      pending = milestones.select { |m| m[:pending] }
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

    def closed_at
      return @closed_at if defined?(@closed_at)

      @closed_at = first_transition_into(role(:resolved))
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
