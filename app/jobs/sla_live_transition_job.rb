# frozen_string_literal: true

# Executes one projected SLA time transition. The calculation token prevents an obsolete job from
# overwriting newer issue state after an edit, reopen, policy change, or another transition job.
class SlaLiveTransitionJob < ActiveJob::Base
  queue_as :default

  def perform(issue_id, calculation_token, transition, transition_token)
    issue = Issue.find_by(id: issue_id)
    row = SlaResult.find_by(issue_id: issue_id)
    return if issue.nil? || row.nil?
    return unless row.calculated_at&.to_i == calculation_token.to_i
    projected_at = { 'at_risk' => row.at_risk_at, 'breach' => row.breach_at,
                     'stale' => row.stale_at }[transition]
    return unless projected_at&.to_i == transition_token.to_i

    outcome = Sla::ResultStore.recalculate(issue, now: Time.current)
    Sla::LiveTransitionScheduler.call(issue, outcome)
  end
end
