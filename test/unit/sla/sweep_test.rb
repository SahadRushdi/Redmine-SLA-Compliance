# frozen_string_literal: true

require_relative '../../test_helper'

# Scheduled at-risk / stale sweep.
# Done when: "A ticket crossing its at-risk window flips to at-risk in the cache within one interval
# and is queued for notification exactly once." Watch out for: idempotency — the sweep runs
# repeatedly and must never double-send.
#
# A fake notifier records every queue call so we can assert exactly-once across repeated sweeps.
# `now:` is injected so time is deterministic without waiting.
class Sla::SweepTest < ActiveSupport::TestCase
  fixtures :projects, :users, :issues, :issue_statuses, :trackers, :enumerations,
           :roles, :members, :member_roles, :enabled_modules

  TRACKER  = 1
  PRIORITY = 6 # High
  NEW      = 1
  CLOSED   = 5

  class FakeNotifier
    attr_reader :calls

    def initialize
      @calls = []
    end

    def enqueue_at_risk(issue, _result)
      @calls << issue.id
    end
  end

  setup do
    User.current = User.find(2)
    @base    = Time.zone.local(2026, 6, 1, 9, 0, 0)
    @project = Project.find(1)
    @project.enable_module!(:sla_compliance)

    @policy = SlaPolicy.create!(project_id: @project.id, enabled: true, coverage_hours: '24x7',
                                first_response_rule: 'either', at_risk_threshold: 80,
                                pause_enabled: true)
    SlaStatusMapping.create!(sla_policy: @policy, role: 'created', status_id: NEW)
    SlaDefinition.create!(sla_policy: @policy, tracker_id: TRACKER, priority_id: PRIORITY,
                          response_seconds: 3600) # 1h response target
  end

  def make_issue(status_id: NEW)
    issue = Issue.new(project_id: @project.id, tracker_id: TRACKER, author_id: 2,
                      priority_id: PRIORITY, status_id: status_id, subject: 'sweep test')
    issue.save!(validate: false)
    issue.update_column(:created_on, @base)
    issue.reload
  end

  def sweep(now:, notifier: FakeNotifier.new)
    summary = Sla::Sweep.new(now: now, notifier: notifier).run
    [summary, notifier]
  end

  def at(hours)
    @base + hours * 3600
  end

  def at_risk_logs(issue)
    SlaNotificationLog.where(issue_id: issue.id, notification_type: 'at_risk').count
  end

  # --- the core acceptance: flip within one interval, queued exactly once, idempotent -------

  test "a ticket crossing its at-risk window flips to at-risk and is queued exactly once" do
    issue = make_issue

    # Interval 1 — 50% of target: on track, not queued.
    _, n1 = sweep(now: at(0.5))
    row = SlaResult.find_by(issue_id: issue.id)
    assert_equal 'met', row.primary_state
    refute row.at_risk
    assert_empty n1.calls

    # Interval 2 — 83% of target: crosses the 80% threshold this interval.
    summary2, n2 = sweep(now: at(50.0 / 60))
    row.reload
    assert row.at_risk, 'must flip to at-risk in the cache within one interval'
    assert_equal [issue.id], n2.calls, 'queued for notification exactly once'
    assert_equal 1, summary2.queued
    assert_equal 1, at_risk_logs(issue), 'exactly one dedup ledger row'

    # Interval 3 — still at risk, no new crossing: must NOT re-queue (idempotent).
    summary3, n3 = sweep(now: at(0.95))
    assert_empty n3.calls, 'the sweep must never double-send'
    assert_equal 0, summary3.queued
    assert_equal 1, at_risk_logs(issue), 'still exactly one ledger row after repeated sweeps'
  end

  # --- idempotency even when re-run at the exact same instant --------------------------------

  test "re-running the sweep at the same instant never queues a second notification" do
    issue = make_issue
    now   = at(50.0 / 60)

    _, first  = sweep(now: now)
    _, second = sweep(now: now)

    assert_equal [issue.id], first.calls
    assert_empty second.calls
    assert_equal 1, at_risk_logs(issue)
  end

  # --- negative cases -----------------------------------------------------------------------

  test "an on-track ticket below the threshold is not queued" do
    issue = make_issue
    _, n = sweep(now: at(0.5)) # 50%
    assert_empty n.calls
    refute SlaResult.find_by(issue_id: issue.id).at_risk
    assert_equal 0, at_risk_logs(issue)
  end

  test "a breached ticket past target is not at-risk and is not queued" do
    issue = make_issue
    _, n = sweep(now: at(3)) # 3h, well past the 1h target
    row = SlaResult.find_by(issue_id: issue.id)
    assert_equal 'breached', row.primary_state
    refute row.at_risk
    assert_empty n.calls
    assert_equal 0, at_risk_logs(issue)
  end

  test "closed issues are skipped by the sweep" do
    closed = make_issue(status_id: CLOSED)
    # Clear any cache row the event-driven save hook created, so what's left is only what the
    # sweep itself writes — the sweep must not touch closed issues.
    SlaResult.delete_all

    _, n = sweep(now: at(50.0 / 60)) # would be at-risk if it were open

    assert_nil SlaResult.find_by(issue_id: closed.id), 'closed issues must not be swept'
    refute_includes n.calls, closed.id
    assert_equal 0, at_risk_logs(closed)
  end

  test "projects without the SLA module enabled are not swept" do
    other = Project.find(2)
    other.disable_module!(:sla_compliance) if other.module_enabled?(:sla_compliance)
    other_issue = Issue.new(project_id: other.id, tracker_id: TRACKER, author_id: 2,
                            priority_id: PRIORITY, status_id: NEW, subject: 'other project')
    other_issue.save!(validate: false)
    other_issue.update_column(:created_on, @base)

    sweep(now: at(50.0 / 60))

    assert_nil SlaResult.find_by(issue_id: other_issue.id)
  end
end
