# frozen_string_literal: true

require_relative '../../test_helper'

# Step 6.3 — Sla::PriorityBreakdown: per-priority effective met/breached/at_risk/no_sla counts for
# the tickets-by-priority stacked bar, over the same Sla::DashboardScope-filtered relation the rest
# of the dashboard uses.
class Sla::PriorityBreakdownTest < ActiveSupport::TestCase
  fixtures :projects, :trackers, :projects_trackers, :issue_statuses, :enumerations, :users,
           :email_addresses, :roles, :members, :member_roles

  LOW  = 4 # position 1
  HIGH = 6 # position 3

  def make_issue(project_id: 1, tracker_id: 1, priority_id: LOW)
    Issue.generate!(project: Project.find(project_id), tracker_id: tracker_id, priority_id: priority_id)
  end

  def make_result(issue, primary_state: 'met', at_risk: false, breach_at: nil, no_sla_reason: nil)
    SlaResult.create!(issue_id: issue.id, project_id: issue.project_id, primary_state: primary_state,
                      at_risk: at_risk, breach_at: breach_at, no_sla_reason: no_sla_reason)
  end

  def scope(project_ids: [1])
    Sla::DashboardScope.call(project_ids: project_ids)
  end

  test "returns one row per priority present in the scope, ordered by IssuePriority position, not insertion order" do
    high_issue = make_issue(priority_id: HIGH)
    low_issue  = make_issue(priority_id: LOW)
    make_result(high_issue)
    make_result(low_issue)

    rows = Sla::PriorityBreakdown.call(scope: scope)

    assert_equal [LOW, HIGH], rows.map(&:priority_id)
    assert_equal %w[Low High], rows.map(&:priority_name)
  end

  test "a priority with zero matching tickets is omitted, not returned as an all-zero row" do
    issue = make_issue(priority_id: LOW)
    make_result(issue)

    rows = Sla::PriorityBreakdown.call(scope: scope)

    refute_includes rows.map(&:priority_id), HIGH
  end

  test "met/breached/no_sla counts per priority use the same effective-state rules as ResultSummary" do
    met_issue      = make_issue(priority_id: HIGH)
    breached_issue = make_issue(priority_id: HIGH)
    live_breached  = make_issue(priority_id: HIGH) # stale met + passed breach_at -> effectively breached
    no_sla_issue   = make_issue(priority_id: HIGH)
    make_result(met_issue, primary_state: 'met')
    make_result(breached_issue, primary_state: 'breached')
    make_result(live_breached, primary_state: 'met', breach_at: 1.hour.ago)
    make_result(no_sla_issue, primary_state: 'no_sla', no_sla_reason: 'not_tracked')

    row = Sla::PriorityBreakdown.call(scope: scope).find { |r| r.priority_id == HIGH }
    summary_counts = Sla::ResultSummary.call(scope: scope(project_ids: [1]).where(issues: { priority_id: HIGH }))

    assert_equal summary_counts.met, row.met
    assert_equal summary_counts.breached, row.breached
    assert_equal summary_counts.no_sla, row.no_sla
    assert_equal 1, row.met
    assert_equal 2, row.breached
    assert_equal 1, row.no_sla
  end

  test "at_risk is reported per row as a subset of met, never counted toward a fourth segment" do
    at_risk_issue = make_issue(priority_id: HIGH)
    make_result(at_risk_issue, primary_state: 'met', at_risk: true, breach_at: 1.hour.from_now)

    row = Sla::PriorityBreakdown.call(scope: scope).find { |r| r.priority_id == HIGH }

    assert_equal 1, row.met
    assert_equal 1, row.at_risk
    assert_equal 1, row.total, 'total = met + breached + no_sla, at_risk is not added in'
  end

  test "an empty/null-relation scope returns an empty array, not an exception" do
    rows = Sla::PriorityBreakdown.call(scope: scope(project_ids: []))

    assert_equal [], rows
  end
end
