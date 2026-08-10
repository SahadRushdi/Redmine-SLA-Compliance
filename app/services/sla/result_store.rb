# frozen_string_literal: true

module Sla
  # Persists an issue's computed SLA `Result` into the `sla_results` cache (one row per
  # issue). This is the write half of the pipeline the dashboard depends on: the dashboard reads
  # only from `sla_results`, never computing on page load, so every recompute path — the
  # event-driven hook, the project/historical recalc, and the sweep — funnels through here.
  #
  # `recalculate` reports whether the ticket's at-risk flag transitioned `false → true` on this
  # recompute (`Outcome`), which the sweep uses to queue an at-risk notification exactly once.
  class ResultStore
    # record       — the persisted SlaResult
    # was_at_risk  — the at_risk value in the cache BEFORE this recompute (false when no prior row)
    # now_at_risk  — the at_risk value AFTER this recompute
    # result       — the classifier's own Result, passed through rather than re-derived. It carries
    #                the at-risk dedup key (`at_risk_target` / `at_risk_since`) that the sweep needs
    #                and the cache has no column for; keeping it here avoids both a migration and a
    #                second classification pass.
    Outcome = Struct.new(:record, :was_at_risk, :now_at_risk, :result, keyword_init: true) do
      # A fresh at-risk transition — the trigger for a one-time notification.
      def newly_at_risk?
        now_at_risk && !was_at_risk
      end
    end

    # Evaluate +issue+ and upsert its cache row. Pass a shared +context+ when recomputing many
    # issues in one project (sweep / project recalc) to skip per-issue policy resolution.
    # @return [Outcome]
    def self.recalculate(issue, context: nil, now: Time.current)
      result = IssueEvaluator.new(issue, context: context, now: now).call

      record      = SlaResult.find_or_initialize_by(issue_id: issue.id)
      was_at_risk = record.persisted? ? record.at_risk? : false

      record.assign_attributes(
        project_id:         issue.project_id,
        primary_state:      result.primary_state,
        no_sla_reason:      result.no_sla_reason,
        at_risk:            result.at_risk || false,
        at_risk_at:         result.at_risk_at,
        breach_at:          result.breach_at,
        response_seconds:   result.response_seconds,
        workaround_seconds: result.workaround_seconds,
        resolution_seconds: result.resolution_seconds,
        update_frequency_seconds: result.update_frequency_seconds,
        deviation_seconds:  result.deviation_seconds,
        cycle_started_at:   result.cycle_started_at,
        resolved_at:        result.resolved_at,
        calculated_at:      now
      )
      record.save!

      Outcome.new(record: record, was_at_risk: was_at_risk, now_at_risk: record.at_risk?,
                  result: result)
    end
  end
end
