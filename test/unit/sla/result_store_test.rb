# frozen_string_literal: true

require_relative '../../test_helper'

# Result persistence (the event-driven recompute's write half).
# Done when: "Editing a ticket updates its cached result." Exercises Sla::ResultStore.recalculate
# end-to-end over REAL issues + hand-built journal histories (the classifier itself is unit-tested
# separately in result_classifier_test.rb). Everything runs inside Redmine's transactional tests
# and is rolled back — nothing persists.
class Sla::ResultStoreTest < ActiveSupport::TestCase
  fixtures :projects, :users, :issues, :issue_statuses, :trackers, :enumerations,
           :roles, :members, :member_roles

  NEW      = 1
  WORK     = 2 # Assigned
  RESOLVED = 3
  TRACKER  = 1
  TRACKED_PRIORITY   = 6 # High
  UNTRACKED_PRIORITY = 4 # Low (no definition)

  setup do
    User.current = User.find(2)
    @project = Project.find(1)
    @base    = Time.zone.local(2026, 6, 1, 9, 0, 0)

    @policy = SlaPolicy.create!(project_id: @project.id, enabled: true, coverage_hours: '24x7',
                                first_response_rule: 'either', at_risk_threshold: 80)
    { created: NEW, work_started: WORK, resolved: RESOLVED }.each do |role, status_id|
      SlaStatusMapping.create!(sla_policy: @policy, role: role.to_s, status_id: status_id)
    end
    # response = 1h, resolution = 2h.
    SlaDefinition.create!(sla_policy: @policy, tracker_id: TRACKER, priority_id: TRACKED_PRIORITY,
                          response_seconds: 3600, resolution_seconds: 7200)
  end

  # --- helpers --------------------------------------------------------------------------

  def make_issue(priority_id: TRACKED_PRIORITY, status_id: NEW)
    issue = Issue.new(project_id: @project.id, tracker_id: TRACKER, author_id: 2,
                      priority_id: priority_id, status_id: status_id, subject: 'SLA store test')
    issue.save!(validate: false)
    issue.update_column(:created_on, @base)
    issue.reload
  end

  def add_status_change(issue, from:, to:, at:)
    journal = Journal.new(journalized: issue, user: User.current, created_on: at)
    journal.details << JournalDetail.new(property: 'attr', prop_key: 'status_id',
                                         old_value: from&.to_s, value: to&.to_s)
    journal.save!
    issue.update_column(:status_id, to)
    journal
  end

  def recalc(issue, now:)
    Sla::ResultStore.recalculate(issue.reload, now: now)
  end

  def at(hours)
    @base + hours * 3600
  end

  # --- create / met ---------------------------------------------------------------------

  test "creates a met cache row for an open, on-track issue" do
    issue = make_issue
    now   = at(0.5) # 30m elapsed, 50% of the 1h response target

    outcome = recalc(issue, now: now)
    row = SlaResult.find_by(issue_id: issue.id)

    assert_not_nil row
    assert_equal @project.id, row.project_id
    assert_equal 'met', row.primary_state
    refute row.at_risk
    assert_equal 1800, row.response_seconds
    assert_nil row.first_response_at, 'elapsed is cached, but the first response is not complete'
    assert_equal now + 1800, row.breach_at   # earliest pending breach = response
    assert_equal now + 1080, row.at_risk_at
    assert_nil row.deviation_seconds
    assert_nil row.resolved_at
    assert_equal now.to_i, row.calculated_at.to_i
    assert_equal row, outcome.record
  end

  # --- editing updates the SAME row -----------------------------------------------------

  test "persists the first response completion timestamp separately from elapsed seconds" do
    issue = make_issue
    journal = Journal.new(journalized: issue, user: User.current, created_on: at(0.5), notes: 'Response')
    journal.save!

    recalc(issue, now: at(1))
    row = SlaResult.find_by!(issue_id: issue.id)

    assert_equal 1800, row.response_seconds
    assert_equal at(0.5).to_i, row.first_response_at.to_i
  end

  test "editing an untracked ticket to a tracked priority updates its cached result in place" do
    issue = make_issue(priority_id: UNTRACKED_PRIORITY)

    recalc(issue, now: at(0.5))
    row = SlaResult.find_by(issue_id: issue.id)
    assert_equal 'no_sla', row.primary_state
    assert_equal 'not_tracked', row.no_sla_reason

    issue.update_column(:priority_id, TRACKED_PRIORITY) # the "edit"
    recalc(issue, now: at(0.5))

    assert_equal 1, SlaResult.where(issue_id: issue.id).count, 'must upsert, not duplicate'
    row.reload
    assert_equal 'met', row.primary_state
    assert_nil row.no_sla_reason
  end

  # --- breached -------------------------------------------------------------------------

  test "open past target is cached as breached with deviation" do
    issue = make_issue
    now   = at(2) # 2h, response target 1h

    recalc(issue, now: now)
    row = SlaResult.find_by(issue_id: issue.id)

    assert_equal 'breached', row.primary_state
    assert_equal 3600, row.deviation_seconds
    assert_equal at(1).to_i, row.deviation_at.to_i
    refute row.at_risk
    assert_nil row.breach_at
  end

  # --- at-risk flag ---------------------------------------------------------------------

  test "open past the at-risk threshold is cached as met AND at_risk with a breach_at" do
    issue = make_issue
    now   = at(50.0 / 60) # 50 minutes = 83% of the 1h response target

    recalc(issue, now: now)
    row = SlaResult.find_by(issue_id: issue.id)

    assert_equal 'met', row.primary_state
    assert row.at_risk
    assert_equal now + 600, row.breach_at
    assert_equal now.to_i, row.at_risk_at.to_i
  end

  # --- resolved within target -----------------------------------------------------------

  test "resolved within target is cached as met with no breach_at" do
    issue = make_issue
    add_status_change(issue, from: NEW, to: RESOLVED, at: at(1)) # resolved 1h in (< 2h)

    recalc(issue, now: at(5))
    row = SlaResult.find_by(issue_id: issue.id)

    assert_equal 'met', row.primary_state
    assert_equal 3600, row.resolution_seconds
    assert_nil row.breach_at
    refute row.at_risk
    assert_equal at(1).to_i, row.resolved_at.to_i
  end

  test "reopening a resolved ticket resets the cached resolved_at to nil until it resolves again" do
    issue = make_issue
    add_status_change(issue, from: NEW, to: RESOLVED, at: at(1))
    recalc(issue, now: at(2))
    row = SlaResult.find_by(issue_id: issue.id)
    assert_not_nil row.resolved_at, 'precondition: resolved once already'

    add_status_change(issue, from: RESOLVED, to: NEW, at: at(3)) # reopen
    recalc(issue, now: at(4))

    assert_nil row.reload.resolved_at
  end

  # Step 6A.6 — the same must hold when the ticket leaves the resolved set for a status that is
  # NOT a `created`-role one (Waiting on Client -> In progress). That path restarts nothing, so
  # before the fix the cached resolved_at survived and the ticket stayed out of the open
  # population for life. This also proves stale rows heal on the next sweep/save: no migration.
  test "leaving a resolved status for a work status clears the cached resolved_at" do
    issue = make_issue
    add_status_change(issue, from: NEW, to: RESOLVED, at: at(1))
    recalc(issue, now: at(2))
    row = SlaResult.find_by(issue_id: issue.id)
    assert_not_nil row.resolved_at, 'precondition: cached as resolved'

    add_status_change(issue, from: RESOLVED, to: WORK, at: at(3))
    recalc(issue, now: at(10))

    assert_nil row.reload.resolved_at, 'it is being worked again — it belongs in the open population'
    assert_equal 'breached', row.primary_state,
                 'and its resolution clock is running again (10h > the 2h target)'
  end

  # --- at-risk transition reporting (drives the sweep's one-time queue) ------------------

  test "Outcome reports the false->true at-risk transition exactly on the crossing recompute" do
    issue = make_issue

    first = recalc(issue, now: at(0.5)) # 50% — not at risk
    refute first.was_at_risk
    refute first.now_at_risk
    refute first.newly_at_risk?

    crossing = recalc(issue, now: at(50.0 / 60)) # 83% — crosses
    refute crossing.was_at_risk
    assert crossing.now_at_risk
    assert crossing.newly_at_risk?

    again = recalc(issue, now: at(0.9)) # 54m, still at risk, no new transition
    assert again.was_at_risk
    assert again.now_at_risk
    refute again.newly_at_risk?
  end
end
