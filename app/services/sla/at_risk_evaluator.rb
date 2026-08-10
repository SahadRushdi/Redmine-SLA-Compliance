# frozen_string_literal: true

module Sla
  # Phase 2 · Step 2.7 — At-risk evaluation.
  #
  # Given the still-pending milestones of an open, SLA-tracked ticket, decides whether the ticket
  # is within the at-risk threshold (a percentage of the target elapsed) of breaching ANY target,
  # and computes the projected `breach_at` (the earliest instant a pending target will breach).
  #
  # At-risk is a FLAG on a "met" ticket, never a distinct primary state — the caller only invokes
  # this for open tickets whose primary state is `met`. Threshold semantics: a milestone is at
  # risk once `elapsed >= threshold% * target` (e.g. 80% ⇒ flag once 80% of the target is used)
  # while still `<= target` (once past target it is breached, not at-risk).
  #
  # Works in both coverage modes because the projection is delegated to the injected calculator's
  # #add (calendar or business-hours). Pure and side-effect free.
  class AtRiskEvaluator
    def initialize(threshold_percent:, calculator:, now: Time.current)
      @fraction   = threshold_percent.to_f / 100.0
      @calculator = calculator
      @now        = now
    end

    # @param milestones [Array<Hash>] each {target:, elapsed:, kind:} — the pending, not-yet-achieved
    #   milestones (with elapsed measured to `now` in the coverage mode). `kind` is optional and only
    #   used to report which target drove the flag.
    # @return [Array(Boolean, Time|nil, Symbol|nil, Time|nil)]
    #   [at_risk, breach_at, at_risk_kind, at_risk_at]
    #   `at_risk_kind` is the flagged milestone closest to breaching — the same one `breach_at`
    #   projects — so a caller can say WHICH target is at risk (Step 8.2 notifies per ticket+target).
    #   Extra array elements preserve existing two-value destructuring while exposing the target
    #   and projected warning time to callers that need them.
    def evaluate(milestones)
      candidates = milestones.reject { |m| m[:elapsed] > m[:target] } # exclude already-breached
      flagged    = candidates.select { |m| m[:elapsed] >= m[:target] * @fraction }
      urgent     = flagged.min_by { |m| m[:target] - m[:elapsed] }

      [flagged.any?, earliest_breach_at(candidates), urgent && urgent[:kind], earliest_at_risk_at(candidates)]
    end

    private

    def earliest_breach_at(milestones)
      milestones.filter_map { |m| project(m) }.min
    end

    def earliest_at_risk_at(milestones)
      milestones.filter_map do |milestone|
        remaining = (milestone[:target] * @fraction) - milestone[:elapsed]
        remaining <= 0 ? @now : @calculator.add(@now, remaining)
      end.min
    end

    def project(milestone)
      remaining = milestone[:target] - milestone[:elapsed]
      return nil if remaining <= 0

      @calculator.add(@now, remaining)
    end
  end
end
