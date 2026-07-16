# frozen_string_literal: true

module Sla
  # The single definition of "effective" SLA state, shared by every reader of the `sla_results`
  # cache (Sla::ResultSummary, Sla::PriorityBreakdown, the dashboard detail table's sort/filter,
  # and per-row view rendering). Without one shared definition, a stale `met` row whose `breach_at`
  # has passed (the sweep hasn't caught up yet) could show as "breached" on the summary cards but
  # "met" in the detail table below them — a visible self-contradiction. See Sla::ResultSummary for
  # the full rationale of the live-reclassification trick these fragments implement.
  #
  # SQL fragments are bind-parameterized (:now, :at_risk_true) for use inside a raw SELECT/WHERE;
  # the instance methods are the Ruby-side equivalent for view code that already has a loaded
  # SlaResult in hand.
  module EffectiveState
    extend ActiveSupport::Concern

    LIVE_BREACHED = "(sla_results.primary_state = 'met' AND sla_results.breach_at IS NOT NULL " \
                    'AND sla_results.breach_at < :now)'
    EFFECTIVE_BREACHED = "(sla_results.primary_state = 'breached' OR #{LIVE_BREACHED})"
    EFFECTIVE_MET      = "(sla_results.primary_state = 'met' AND NOT #{LIVE_BREACHED})"
    EFFECTIVE_AT_RISK  = "(sla_results.at_risk = :at_risk_true AND #{EFFECTIVE_MET})"
    EFFECTIVE_NO_SLA   = "(sla_results.primary_state = 'no_sla')"

    # ORDER BY rank for a detail-table "Result" column sort: breached first, then met, then no_sla
    # last — same effective-state definition as everywhere else, so a sort-by-result order can
    # never disagree with the state-filter tabs or the summary cards.
    ORDER_RANK_SQL = "(CASE WHEN #{EFFECTIVE_BREACHED} THEN 0 WHEN #{EFFECTIVE_NO_SLA} THEN 2 ELSE 1 END)"

    # 'met' | 'breached' | 'no_sla', reclassifying a stale-met/live-breached row without touching
    # the persisted cache.
    def effective_primary_state(now = Time.current)
      return 'no_sla' if no_sla?

      primary_state == 'breached' || live_breached?(now) ? 'breached' : 'met'
    end

    # at_risk is only ever meaningful as a subset of an effectively-met row — a row whose breach_at
    # has since passed is live-reclassified to breached and can no longer be "at risk" of it.
    def effective_at_risk?(now = Time.current)
      at_risk? && effective_primary_state(now) == 'met'
    end

    private

    def live_breached?(now)
      primary_state == 'met' && breach_at.present? && breach_at < now
    end
  end
end
