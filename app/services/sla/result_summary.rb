# frozen_string_literal: true

module Sla
  # Live-accurate met/breached/at_risk/no_sla counts over the `sla_results` cache — the read half
  # that lets a dashboard show real-time compliance counts without a recurring full-ticket scan or
  # rebuilding SLA timelines on page load (Global Rule 4).
  #
  # The trick: `breach_at` (see ResultClassifier#risk) is only ever non-nil while a ticket is still
  # open and currently classified `met`, and it's already a precomputed wall-clock instant (the
  # moment `elapsed` will equal `target`). So a `met` row whose `breach_at` has already passed is,
  # right now, actually breached — the sweep just hasn't caught up yet. Reclassifying that at read
  # time is one indexed comparison, not an engine re-run, and never touches the persisted cache.
  #
  # `at_risk_at` provides the equivalent projection for the warning window, so at-risk and breach
  # transitions are both evaluated live with indexed timestamp comparisons.
  #
  # `not_configured`/`not_tracked` split `no_sla` by `sla_results.no_sla_reason` (Step 6.2's card
  # breakdown). `no_sla_reason` is nullable at the DB level even though ResultClassifier always
  # sets it alongside `primary_state = 'no_sla'` — a hypothetical nil-reason row would count
  # toward `no_sla` but neither breakdown field, so `no_sla == not_configured + not_tracked` is
  # not a schema-enforced guarantee, only an engine-contract one.
  class ResultSummary
    Counts = Struct.new(:total, :met, :breached, :at_risk, :no_sla,
                         :not_configured, :not_tracked, keyword_init: true) do
      # Tickets that actually had an SLA to meet — the correct denominator for a "% SLA met"
      # figure, since a No-SLA ticket was never evaluated and must not drag the percentage down.
      # Defined here, once, so the SLA Met card and any future consumer cannot disagree about it.
      def evaluated
        met + breached
      end
    end

    # The live-reclassification SQL fragments themselves live on Sla::EffectiveState (included
    # into SlaResult) — shared with Sla::PriorityBreakdown, the dashboard detail table, and
    # per-row view rendering so every reader of the cache agrees on what "effective" means.
    EFFECTIVE_MET      = Sla::EffectiveState::EFFECTIVE_MET
    EFFECTIVE_BREACHED = Sla::EffectiveState::EFFECTIVE_BREACHED
    EFFECTIVE_AT_RISK  = Sla::EffectiveState::EFFECTIVE_AT_RISK

    # Aliases deliberately avoid the real `sla_results` column names (e.g. `at_risk` is itself a
    # boolean column) — Rails type-casts a select() alias using any real attribute of the same name,
    # which would silently coerce these integer counts through the boolean caster.
    AGGREGATE_SQL = <<~SQL.squish
      COUNT(*) AS total_count,
      SUM(CASE WHEN #{EFFECTIVE_MET} THEN 1 ELSE 0 END) AS met_count,
      SUM(CASE WHEN #{EFFECTIVE_BREACHED} THEN 1 ELSE 0 END) AS breached_count,
      SUM(CASE WHEN #{EFFECTIVE_AT_RISK} THEN 1 ELSE 0 END) AS at_risk_count,
      SUM(CASE WHEN sla_results.primary_state = 'no_sla' THEN 1 ELSE 0 END) AS no_sla_count,
      SUM(CASE WHEN sla_results.primary_state = 'no_sla'
               AND sla_results.no_sla_reason = 'not_configured' THEN 1 ELSE 0 END) AS not_configured_count,
      SUM(CASE WHEN sla_results.primary_state = 'no_sla'
               AND sla_results.no_sla_reason = 'not_tracked' THEN 1 ELSE 0 END) AS not_tracked_count
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

      # A scope with a statically-impossible WHERE clause (e.g. `where(project_id: [])`, which the
      # dashboard legitimately builds whenever a user has zero permitted projects) short-circuits
      # to an ActiveRecord null relation — `.take` returns nil without ever issuing SQL, unlike a
      # scope that runs a real query and matches zero rows (which still returns one all-zero
      # aggregate row, per ordinary SQL aggregate semantics with no GROUP BY).
      return Counts.new(total: 0, met: 0, breached: 0, at_risk: 0, no_sla: 0,
                        not_configured: 0, not_tracked: 0) if row.nil?

      Counts.new(total: row.total_count.to_i, met: row.met_count.to_i,
                 breached: row.breached_count.to_i, at_risk: row.at_risk_count.to_i,
                 no_sla: row.no_sla_count.to_i, not_configured: row.not_configured_count.to_i,
                 not_tracked: row.not_tracked_count.to_i)
    end
  end
end
