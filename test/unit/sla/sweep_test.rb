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
  RESOLVED = 3 # NOT is_closed in Redmine's fixtures — which is exactly why it's interesting here
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

  class FakeStaleNotifier
    attr_reader :calls

    def initialize
      @calls = []
    end

    def enqueue_stale_digest(project, issues)
      @calls << [project.id, issues.map(&:id)]
    end
  end

  setup do
    User.current = User.find(2)
    @base    = Time.zone.local(2026, 6, 1, 9, 0, 0)
    @project = Project.find(1)
    @project.enable_module!(:sla_compliance)
    # Fixture issues (created ~2006) are ancient relative to @base, so if left open they'd read
    # as trivially "stale" the instant they're not_tracked — swamping the stale-digest tests
    # below with noise unrelated to what each test explicitly sets up. Closing them doesn't
    # affect the at-risk tests (breached fixture issues were never assertable candidates anyway).
    Issue.where(project_id: @project.id).open.update_all(status_id: CLOSED)

    @policy = SlaPolicy.create!(project_id: @project.id, enabled: true, coverage_hours: '24x7',
                                first_response_rule: 'either', at_risk_threshold: 80,
                                pause_enabled: true)
    SlaStatusMapping.create!(sla_policy: @policy, role: 'created', status_id: NEW)
    SlaDefinition.create!(sla_policy: @policy, tracker_id: TRACKER, priority_id: PRIORITY,
                          response_seconds: 3600) # 1h response target
  end

  def make_issue(status_id: NEW, priority_id: PRIORITY)
    issue = Issue.new(project_id: @project.id, tracker_id: TRACKER, author_id: 2,
                      priority_id: priority_id, status_id: status_id, subject: 'sweep test')
    issue.save!(validate: false)
    issue.update_column(:created_on, @base)
    issue.reload
  end

  # A status transition journal, mirroring timeline_builder_test.rb's helper — also updates the
  # issue's CURRENT status_id, since the sweep's `open_issues` scope (and TimelineBuilder's
  # journal-history reconstruction) both need it to reflect reality, not just the journal record.
  def add_status_change(issue, from:, to:, at:)
    journal = Journal.new(journalized: issue, user: User.current, created_on: at)
    journal.details << JournalDetail.new(property: 'attr', prop_key: 'status_id',
                                         old_value: from.to_s, value: to.to_s)
    journal.save!
    issue.update_column(:status_id, to)
  end

  def sweep(now:, notifier: FakeNotifier.new, stale_notifier: FakeStaleNotifier.new)
    summary = Sla::Sweep.new(now: now, notifier: notifier, stale_notifier: stale_notifier).run
    [summary, notifier, stale_notifier]
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

  # --- reopen restarts the measurement cycle -> a second notification is allowed (A2) ---------

  test "reopening after resolution starts a new cycle and allows a second at-risk notification" do
    issue = make_issue

    # Cycle 1: crosses the at-risk threshold and is notified once.
    _, first = sweep(now: at(50.0 / 60))
    assert_equal [issue.id], first.calls
    assert_equal 1, at_risk_logs(issue)

    # Resolved shortly after, then reopened two days later — Fixed Decisions: reopened tickets
    # restart the SLA clock from zero.
    add_status_change(issue, from: NEW, to: CLOSED, at: at(55.0 / 60))
    add_status_change(issue, from: CLOSED, to: NEW, at: @base + 2.days)

    # Immediately after reopening, cycle 2 has barely started: not yet at-risk, and the old
    # (lifetime-scoped, pre-fix) dedup key would have wrongly blocked this if it fired.
    _, right_after_reopen = sweep(now: @base + 2.days + 1.minute)
    assert_empty right_after_reopen.calls
    assert_equal 1, at_risk_logs(issue), 'still just the one notification from cycle 1'

    # 83% of the target, measured from the reopen (the new clock_start), not the original creation.
    _, second = sweep(now: @base + 2.days + 50.minutes)
    assert_equal [issue.id], second.calls, 'reopening must allow a fresh at-risk notification'
    assert_equal 2, at_risk_logs(issue), 'two distinct cycles, two distinct notifications'

    cycle_keys = SlaNotificationLog.where(issue_id: issue.id, notification_type: 'at_risk')
                                   .pluck(:cycle_key)
    assert_equal 2, cycle_keys.uniq.size, 'each cycle must claim its own dedup key'
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

  # --- "open" is the policy's own resolved-role mapping, not Redmine's is_closed --------------
  # The dashboard counts open tickets as "not resolved" per the policy. The sweep has to agree, or
  # a ticket the dashboard still shows as open would stop being re-evaluated and its at-risk flag
  # and breach_at would freeze at whatever the last event left behind.

  test "a ticket in a resolved-role status is not swept, even though Redmine calls it open" do
    SlaStatusMapping.create!(sla_policy: @policy, role: 'resolved', status_id: RESOLVED)
    resolved = make_issue(status_id: RESOLVED)
    assert Issue.open.exists?(resolved.id), 'guard: Redmine itself treats Resolved as open'
    SlaResult.delete_all

    _, n = sweep(now: at(50.0 / 60)) # would be at-risk if its clock were still running

    assert_nil SlaResult.find_by(issue_id: resolved.id)
    assert_empty n.calls
  end

  test "a Redmine-closed ticket the policy never mapped to `resolved` is still swept" do
    SlaStatusMapping.create!(sla_policy: @policy, role: 'resolved', status_id: RESOLVED)
    # CLOSED is is_closed in Redmine but is NOT one of this policy's resolved statuses, so the
    # SLA clock is still running on it and the sweep must keep re-evaluating it.
    closed_but_unresolved = make_issue(status_id: CLOSED)
    SlaResult.delete_all

    _, n = sweep(now: at(50.0 / 60))

    row = SlaResult.find_by(issue_id: closed_but_unresolved.id)
    assert_not_nil row, 'Issue.open would have skipped this ticket entirely'
    assert row.at_risk, 'its clock is still running, so it can still cross the at-risk threshold'
    assert_equal [closed_but_unresolved.id], n.calls
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

  # --- stale-ticket digest (Step 2.8 wired into the sweep, Phase 3 hardening) -----------------
  #
  # UNTRACKED_PRIORITY has no SlaDefinition on TRACKER, so an issue with it classifies as
  # no_sla/not_tracked ("unset target") — the exact Step 2.8 scope, distinct from not_configured.
  UNTRACKED_PRIORITY = 5 # "Normal" in fixtures; not covered by the setup's SlaDefinition

  def enable_stale_digest(threshold_days: 5, frequency: 'weekly', last_at: nil)
    SlaNotificationSetting.create!(project_id: @project.id, stale_email_enabled: true,
                                   stale_email_frequency: frequency,
                                   stale_threshold_days: threshold_days,
                                   last_stale_digest_at: last_at)
  end

  test "an excluded ticket past its inactivity threshold is queued in the stale digest" do
    enable_stale_digest(threshold_days: 5)
    issue = make_issue(priority_id: UNTRACKED_PRIORITY)

    _, _, stale = sweep(now: @base + 6.days)

    assert_equal [[@project.id, [issue.id]]], stale.calls
    assert_equal 1, SlaNotificationLog.where(issue_id: issue.id, notification_type: 'stale').count
  end

  test "an excluded ticket below its inactivity threshold is not queued" do
    enable_stale_digest(threshold_days: 5)
    make_issue(priority_id: UNTRACKED_PRIORITY)

    summary, _, stale = sweep(now: @base + 4.days)

    assert_equal 0, summary.stale_queued
    assert_empty stale.calls
  end

  test "stale digest is skipped entirely when the project has not enabled stale email" do
    issue = make_issue(priority_id: UNTRACKED_PRIORITY)

    summary, _, stale = sweep(now: @base + 30.days)

    assert_equal 0, summary.stale_queued
    assert_empty stale.calls
    assert_equal 0, SlaNotificationLog.where(issue_id: issue.id, notification_type: 'stale').count
  end

  test "a not_configured ticket (tracker with no SlaDefinition at all) never enters the stale digest" do
    enable_stale_digest(threshold_days: 5)
    unconfigured_tracker_issue = Issue.new(project_id: @project.id, tracker_id: 2, author_id: 2,
                                           priority_id: UNTRACKED_PRIORITY, status_id: NEW,
                                           subject: 'unconfigured tracker')
    unconfigured_tracker_issue.save!(validate: false)
    unconfigured_tracker_issue.update_column(:created_on, @base)

    _, _, stale = sweep(now: @base + 30.days)

    assert_empty stale.calls
  end

  test "the digest window is claimed once and not re-claimed until the frequency elapses" do
    # A digest already ran 3 days ago; weekly frequency means the next one isn't due for 4 more.
    enable_stale_digest(threshold_days: 1, frequency: 'weekly', last_at: @base + 3.days)
    issue = make_issue(priority_id: UNTRACKED_PRIORITY)

    # The ticket itself is well past its 1-day threshold, but the project's digest window isn't
    # due yet — the schedule gate, not per-ticket staleness, decides whether a digest fires.
    summary, _, stale = sweep(now: @base + 5.days)
    assert_equal 0, summary.stale_queued
    assert_empty stale.calls

    # Once the weekly window has elapsed since the last digest, it fires.
    summary2, _, stale2 = sweep(now: @base + 10.days)
    assert_equal 1, summary2.stale_queued
    assert_equal [issue.id], stale2.calls.first.last
  end

  # A3: a still-stale ticket must appear in EVERY digest window it's stale for, not just once
  # ever — a lifetime-scoped dedup key would silently suppress it after its first appearance,
  # defeating the entire point of a recurring "don't forget about excluded tickets" digest.
  test "a still-stale ticket appears again in the next digest window, not just once ever" do
    enable_stale_digest(threshold_days: 1, frequency: 'weekly')
    issue = make_issue(priority_id: UNTRACKED_PRIORITY)

    _, _, window1 = sweep(now: @base + 2.days)
    assert_equal [issue.id], window1.calls.first.last, 'appears in the first window'

    # A full week later: a new digest window, and the ticket is STILL stale (no activity since).
    _, _, window2 = sweep(now: @base + 9.days)
    assert_equal [issue.id], window2.calls.first.last,
                 'a still-stale ticket must appear again in the next window, not be suppressed'

    logs = SlaNotificationLog.where(issue_id: issue.id, notification_type: 'stale')
    assert_equal 2, logs.count, 'one ledger row per window the ticket appeared in'
    assert_equal 2, logs.pluck(:cycle_key).uniq.size, 'each window claims its own dedup key'
  end

  test "repeated sweeps within the same digest window never queue the same ticket twice" do
    enable_stale_digest(threshold_days: 1)
    issue = make_issue(priority_id: UNTRACKED_PRIORITY)

    sweep(now: @base + 2.days)
    _, _, stale2 = sweep(now: @base + 2.days + 1.hour)

    assert_empty stale2.calls, 'the digest window was already claimed by the first sweep'
    assert_equal 1, SlaNotificationLog.where(issue_id: issue.id, notification_type: 'stale').count
  end
end
