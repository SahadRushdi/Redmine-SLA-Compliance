# frozen_string_literal: true

module Sla
  # Step 6.3 — per-priority effective met/breached/no_sla counts for the tickets-by-priority
  # stacked bar, given the same Sla::DashboardScope-filtered relation the rest of the dashboard
  # uses. Ordered by Redmine's own IssuePriority position (Global Rule 1: never a hardcoded
  # priority order/name). `at_risk` is reported per row for tooltip use only — it is always a
  # subset of `met`, never its own stacked segment, mirroring the compliance donut's sub-band rule.
  class PriorityBreakdown
    Row = Struct.new(:priority_id, :priority_name, :met, :breached, :at_risk, :no_sla, :total,
                     keyword_init: true)

    GROUPED_SQL = <<~SQL.squish
      SUM(CASE WHEN #{Sla::EffectiveState::EFFECTIVE_MET} THEN 1 ELSE 0 END) AS met_count,
      SUM(CASE WHEN #{Sla::EffectiveState::EFFECTIVE_BREACHED} THEN 1 ELSE 0 END) AS breached_count,
      SUM(CASE WHEN #{Sla::EffectiveState::EFFECTIVE_AT_RISK} THEN 1 ELSE 0 END) AS at_risk_count,
      SUM(CASE WHEN #{Sla::EffectiveState::EFFECTIVE_NO_SLA} THEN 1 ELSE 0 END) AS no_sla_count
    SQL

    def self.call(scope:, now: Time.current)
      new(scope: scope, now: now).call
    end

    def initialize(scope:, now: Time.current)
      @scope = scope
      @now   = now
    end

    # Uses .select + .index_by rather than .pluck with a multi-column raw SQL string — pluck's
    # column-splitting for a single comma-containing raw SQL argument isn't reliable across
    # MySQL/PostgreSQL/SQLite, the three adapters Redmine supports.
    def call
      grouped = @scope.reorder(nil).unscope(:includes)
                      .group('issues.priority_id')
                      .select(ActiveRecord::Base.sanitize_sql_array(
                        ["issues.priority_id AS priority_id_value, #{GROUPED_SQL}",
                         now: @now, at_risk_true: true]))
      by_priority = grouped.index_by { |r| r.priority_id_value }

      IssuePriority.where(id: by_priority.keys).sorted.map do |priority|
        row = by_priority[priority.id]
        Row.new(priority_id: priority.id, priority_name: priority.name,
                met: row.met_count.to_i, breached: row.breached_count.to_i,
                at_risk: row.at_risk_count.to_i, no_sla: row.no_sla_count.to_i,
                total: row.met_count.to_i + row.breached_count.to_i + row.no_sla_count.to_i)
      end
    end
  end
end
