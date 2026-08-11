# frozen_string_literal: true

require_relative '../../test_helper'

class Sla::LiveTransitionSchedulerTest < ActiveSupport::TestCase
  IssueStub = Struct.new(:id, :project)
  ResultStub = Struct.new(:at_risk_at, :breach_at, :calculated_at)
  ClassificationStub = Struct.new(:at_risk_target, :at_risk_since, :cycle_started_at)
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

  test 'does not claim or notify an at-risk transition without effective email settings' do
    now = Time.zone.local(2026, 8, 10, 10, 0)
    project = Object.new
    outcome = OutcomeStub.new(ResultStub.new(nil, nil, now), ClassificationStub.new, true)
    resolver = mock('notification-resolver')
    resolver.expects(:resolve).with(:at_risk_email)
            .returns(Sla::NotificationSettingsResolver::Resolution.new)
    Sla::NotificationSettingsResolver.expects(:new).with(project).returns(resolver)
    SlaNotificationLog.expects(:claim!).never

    Sla::LiveTransitionScheduler.call(IssueStub.new(42, project), outcome, now: now)
  end

  test 'passes the effective setting to the notifier after winning the dedup claim' do
    now = Time.zone.local(2026, 8, 10, 10, 0)
    project = Object.new
    issue = IssueStub.new(42, project)
    row = ResultStub.new(nil, nil, now)
    result = ClassificationStub.new('response', now - 1.minute, now - 1.hour)
    outcome = OutcomeStub.new(row, result, true)
    setting = SlaNotificationSetting.new(project_id: 1)
    resolver = mock('notification-resolver')
    resolver.expects(:resolve).with(:at_risk_email)
            .returns(Sla::NotificationSettingsResolver::Resolution.new(setting: setting))
    Sla::NotificationSettingsResolver.expects(:new).with(project).returns(resolver)
    SlaNotificationLog.expects(:claim!).returns(true)
    Sla::AtRiskNotifier.any_instance.expects(:enqueue_at_risk)
                       .with(issue, row, setting: setting)

    Sla::LiveTransitionScheduler.call(issue, outcome, now: now)
  end
end
