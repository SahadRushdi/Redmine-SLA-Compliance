# frozen_string_literal: true

require_relative '../../test_helper'

# Step 6.1 — Sla::DashboardScope: the filtered sla_results relation behind the dashboard's
# Project/Tracker/Priority filters plus its two time filters (open_only for the current-state
# population, resolved_range for the SLA Met window). sla_results has no tracker_id/priority_id
# columns of its own, so those filters have to prove they actually reach through the `issues` join.
class Sla::DashboardScopeTest < ActiveSupport::TestCase
  fixtures :projects, :trackers, :projects_trackers, :issue_statuses, :enumerations, :users,
           :email_addresses, :roles, :members, :member_roles

  def make_issue(project_id: 1, tracker_id: 1, priority_id: 4, created_on: Time.zone.now)
    issue = Issue.generate!(project: Project.find(project_id), tracker_id: tracker_id,
                            priority_id: priority_id)
    issue.update_column(:created_on, created_on)
    issue
  end

  def make_result(issue, project_id: nil, resolved_at: nil, primary_state: 'met')
    SlaResult.create!(issue_id: issue.id, project_id: project_id || issue.project_id,
                      primary_state: primary_state, resolved_at: resolved_at)
  end

  test 'excludes No-SLA rows from the dashboard population' do
    evaluated_issue = make_issue
    no_sla_issue = make_issue
    make_result(evaluated_issue, primary_state: 'met')
    make_result(no_sla_issue, primary_state: 'no_sla')

    scope = Sla::DashboardScope.call(project_ids: [1])

    assert_equal [evaluated_issue.id], scope.pluck(:issue_id)
  end

  test 'scopes to the given project_ids only' do
    issue_a = make_issue(project_id: 1)
    issue_b = make_issue(project_id: 3)
    make_result(issue_a)
    make_result(issue_b)

    scope = Sla::DashboardScope.call(project_ids: [1])

    assert_equal [issue_a.id], scope.pluck(:issue_id)
  end

  test 'filters by tracker_id via the issues join' do
    matching = make_issue(tracker_id: 1)
    other = make_issue(tracker_id: 2)
    make_result(matching)
    make_result(other)

    scope = Sla::DashboardScope.call(project_ids: [1], tracker_ids: [1])

    assert_equal [matching.id], scope.pluck(:issue_id)
  end

  test 'filters by priority_ids via the issues join' do
    matching = make_issue(priority_id: 4)
    other = make_issue(priority_id: 5)
    make_result(matching)
    make_result(other)

    scope = Sla::DashboardScope.call(project_ids: [1], priority_ids: [4])

    assert_equal [matching.id], scope.pluck(:issue_id)
  end

  # "Open" is the engine's own resolved-role milestone persisted as sla_results.resolved_at, NOT
  # Redmine's is_closed — the whole point of the open-ticket dashboard semantics.
  test 'open_only keeps unresolved rows and drops resolved ones' do
    open_issue = make_issue
    resolved_issue = make_issue
    make_result(open_issue)
    make_result(resolved_issue, resolved_at: Time.zone.local(2026, 7, 10, 9, 0, 0))

    scope = Sla::DashboardScope.call(project_ids: [1], open_only: true)

    assert_equal [open_issue.id], scope.pluck(:issue_id)
  end

  test 'open_only is not applied unless asked for' do
    open_issue = make_issue
    resolved_issue = make_issue
    make_result(open_issue)
    make_result(resolved_issue, resolved_at: Time.zone.local(2026, 7, 10, 9, 0, 0))

    scope = Sla::DashboardScope.call(project_ids: [1])

    assert_equal [open_issue.id, resolved_issue.id].sort, scope.pluck(:issue_id).sort
  end

  test 'resolved_range filters on resolved_at, not created_on' do
    # Both created outside the window; only the resolution date decides membership.
    in_window = make_issue(created_on: Date.new(2026, 1, 5).to_time)
    out_of_window = make_issue(created_on: Date.new(2026, 7, 10).to_time)
    make_result(in_window, resolved_at: Time.zone.local(2026, 7, 10, 9, 0, 0))
    make_result(out_of_window, resolved_at: Time.zone.local(2026, 8, 2, 9, 0, 0))

    scope = Sla::DashboardScope.call(project_ids: [1],
                                     resolved_range: Date.new(2026, 7, 1)..Date.new(2026, 7, 31))

    assert_equal [in_window.id], scope.pluck(:issue_id)
  end

  # A Date range cast straight onto a datetime column truncates the last day at midnight, which
  # would silently drop everything resolved during it.
  test 'resolved_range covers the whole of the last day in the window' do
    late_on_last_day = make_issue
    make_result(late_on_last_day, resolved_at: Time.zone.local(2026, 7, 31, 16, 20, 0))

    scope = Sla::DashboardScope.call(project_ids: [1],
                                     resolved_range: Date.new(2026, 7, 1)..Date.new(2026, 7, 31))

    assert_equal [late_on_last_day.id], scope.pluck(:issue_id)
  end

  test 'resolved_range excludes rows that were never resolved' do
    still_open = make_issue
    make_result(still_open)

    scope = Sla::DashboardScope.call(project_ids: [1],
                                     resolved_range: Date.new(2026, 7, 1)..Date.new(2026, 7, 31))

    assert_empty scope.pluck(:issue_id)
  end

  test 'combines project + tracker + priority + open_only with AND semantics' do
    matches_all = make_issue(project_id: 1, tracker_id: 1, priority_id: 4)
    wrong_tracker = make_issue(project_id: 1, tracker_id: 2, priority_id: 4)
    resolved = make_issue(project_id: 1, tracker_id: 1, priority_id: 4)
    make_result(matches_all)
    make_result(wrong_tracker)
    make_result(resolved, resolved_at: Time.zone.local(2026, 7, 10, 9, 0, 0))

    scope = Sla::DashboardScope.call(project_ids: [1], tracker_ids: [1], priority_ids: [4],
                                     open_only: true)

    assert_equal [matches_all.id], scope.pluck(:issue_id)
  end

  test 'the returned relation composes with Sla::ResultSummary.call(scope:)' do
    issue = make_issue
    make_result(issue)

    scope = Sla::DashboardScope.call(project_ids: [1])
    counts = Sla::ResultSummary.call(scope: scope)

    assert_equal 1, counts.total
    assert_equal 1, counts.met
  end
end
