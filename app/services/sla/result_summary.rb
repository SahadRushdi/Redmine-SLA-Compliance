# frozen_string_literal: true

module Sla
  # Live-accurate met/breached/at_risk/no_sla counts over the `sla_results` cache — the read half
  # that lets a dashboard show real-time compliance counts without shortening the sweep interval or
  # computing SLA state on page load (Global Rule 4).
  #
  # The trick: `breach_at` (see ResultClassifier#risk) is only ever non-nil while a ticket is still
  # open and currently classified `met`, and it's already a precomputed wall-clock instant (the
  # moment `elapsed` will equal `target`). So a `met` row whose `breach_at` has already passed is,
  # right now, actually breached — the sweep just hasn't caught up yet. Reclassifying that at read
  # time is one indexed comparison, not an engine re-run, and never touches the persisted cache.
  #
  # At-risk is NOT given the same live treatment: there is no precomputed instant to compare
  # against (only a boolean, refreshed solely by the full engine pass), so at-risk counts still
  # reflect the last sweep/event, same as today.
  class ResultSummary
    Counts = Struct.new(:total, :met, :breached, :at_risk, :no_sla, keyword_init: true)

    LIVE_BREACHED = "(sla_results.primary_state = 'met' AND sla_results.breach_at IS NOT NULL " \
                    'AND sla_results.breach_at < :now)'
    EFFECTIVE_BREACHED = "(sla_results.primary_state = 'breached' OR #{LIVE_BREACHED})"
    EFFECTIVE_MET      = "(sla_results.primary_state = 'met' AND NOT #{LIVE_BREACHED})"
    EFFECTIVE_AT_RISK  = "(sla_results.at_risk = :at_risk_true AND #{EFFECTIVE_MET})"

    # Aliases deliberately avoid the real `sla_results` column names (e.g. `at_risk` is itself a
    # boolean column) — Rails type-casts a select() alias using any real attribute of the same name,
    # which would silently coerce these integer counts through the boolean caster.
    AGGREGATE_SQL = <<~SQL.squish
      COUNT(*) AS total_count,
      SUM(CASE WHEN #{EFFECTIVE_MET} THEN 1 ELSE 0 END) AS met_count,
      SUM(CASE WHEN #{EFFECTIVE_BREACHED} THEN 1 ELSE 0 END) AS breached_count,
      SUM(CASE WHEN #{EFFECTIVE_AT_RISK} THEN 1 ELSE 0 END) AS at_risk_count,
      SUM(CASE WHEN sla_results.primary_state = 'no_sla' THEN 1 ELSE 0 END) AS no_sla_count
    SQL

    def self.call(scope: default_relation, now: Time.current)
      new(scope: scope, now: now).call
    end

    # Active projects with the SLA module enabled — mirrors Sweep#swept_projects so a summary never
    # counts rows the hook/sweep have stopped maintaining (archived or module-disabled projects).
    # Does not apply permission scoping; a real dashboard controller passes its own scope in.
    def self.default_relation
      SlaResult.where(project_id: Project.active.has_module(:sla_compliance).select(:id))
    end

    def initialize(scope: self.class.default_relation, now: Time.current)
      @scope = scope
      @now   = now
    end

    def call
      row = @scope
            .reorder(nil)
            .unscope(:includes)
            .select(ActiveRecord::Base.sanitize_sql_array([AGGREGATE_SQL, now: @now, at_risk_true: true]))
            .take

      Counts.new(total: row.total_count.to_i, met: row.met_count.to_i,
                 breached: row.breached_count.to_i, at_risk: row.at_risk_count.to_i,
                 no_sla: row.no_sla_count.to_i)
    end
  end
end
