# frozen_string_literal: true

require_relative '../../test_helper'

class Sla::LiveTransitionSchedulerTest < ActiveSupport::TestCase
  IssueStub = Struct.new(:id)
  ResultStub = Struct.new(:at_risk_at, :breach_at, :calculated_at)
  OutcomeStub = Struct.new(:record, :result, :newly_at_risk_value) do
    def newly_at_risk?
      newly_at_risk_value
    end
  end

  test 'queues only the two projected future transitions for one issue' do
    now = Time.zone.local(2026, 8, 10, 10, 0)
    row = ResultStub.new(now + 10.minutes, now + 30.minutes, now)
    outcome = OutcomeStub.new(row, nil, false)
    proxy = mock('configured-job')

    SlaLiveTransitionJob.expects(:set).with(wait_until: row.at_risk_at).returns(proxy)
    proxy.expects(:perform_later).with(42, now.to_i, 'at_risk', row.at_risk_at.to_i)
    SlaLiveTransitionJob.expects(:set).with(wait_until: row.breach_at + 1.second).returns(proxy)
    proxy.expects(:perform_later).with(42, now.to_i, 'breach', row.breach_at.to_i)

    Sla::LiveTransitionScheduler.call(IssueStub.new(42), outcome, now: now)
  end

  test 'does not queue transitions that are already due or absent' do
    now = Time.zone.local(2026, 8, 10, 10, 0)
    outcome = OutcomeStub.new(ResultStub.new(now, nil, now), nil, false)
    SlaLiveTransitionJob.expects(:set).never

    Sla::LiveTransitionScheduler.call(IssueStub.new(42), outcome, now: now)
  end
end
