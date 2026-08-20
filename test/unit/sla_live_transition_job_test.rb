# frozen_string_literal: true

require_relative '../test_helper'

class SlaLiveTransitionJobTest < ActiveSupport::TestCase
  fixtures :projects, :issues

  test 'an obsolete transition job does not recalculate the issue' do
    issue = Issue.find(1)
    calculated_at = Time.zone.local(2026, 8, 10, 10, 0)
    old_projection = calculated_at + 10.minutes
    SlaResult.create!(issue_id: issue.id, project_id: issue.project_id, primary_state: 'met',
                      at_risk: false, at_risk_at: old_projection + 5.minutes,
                      breach_at: calculated_at + 1.hour, calculated_at: calculated_at)
    Sla::ResultStore.expects(:recalculate).never

    SlaLiveTransitionJob.new.perform(issue.id, calculated_at.to_i, 'at_risk', old_projection.to_i)
  end

  test 'a matching transition recalculates and schedules the next projection' do
    issue = Issue.find(1)
    calculated_at = Time.zone.local(2026, 8, 10, 10, 0)
    projection = calculated_at + 10.minutes
    SlaResult.create!(issue_id: issue.id, project_id: issue.project_id, primary_state: 'met',
                      at_risk: false, at_risk_at: projection,
                      breach_at: calculated_at + 1.hour, calculated_at: calculated_at)
    outcome = mock('outcome')
    Sla::ResultStore.expects(:recalculate).with(issue, now: instance_of(ActiveSupport::TimeWithZone)).returns(outcome)
    Sla::LiveTransitionScheduler.expects(:call).with(issue, outcome)

    SlaLiveTransitionJob.new.perform(issue.id, calculated_at.to_i, 'at_risk', projection.to_i)
  end
end
