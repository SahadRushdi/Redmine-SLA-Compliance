# frozen_string_literal: true

require_relative '../../test_helper'

# Step 6.1 — Sla::DashboardScope: the filtered sla_results relation behind the dashboard's
# Project/Tracker/Priority/Date filters. sla_results has no tracker_id/priority_id/created_on
# columns of its own, so every filter here has to prove it actually reaches through the `issues`
# join, not just an sla_results column.
class Sla::DashboardScopeTest < ActiveSupport::TestCase
  fixtures :projects, :trackers, :projects_trackers, :issue_statuses, :enumerations, :users,
           :email_addresses, :roles, :members, :member_roles

  def make_issue(project_id: 1, tracker_id: 1, priority_id: 4, created_on: Time.zone.now)
    issue = Issue.generate!(project: Project.find(project_id), tracker_id: tracker_id,
                            priority_id: priority_id)
    issue.update_column(:created_on, created_on)
    issue
  end

  def make_result(issue, project_id: nil)
    SlaResult.create!(issue_id: issue.id, project_id: project_id || issue.project_id,
                      primary_state: 'met')
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

  test 'filters by created_on date range via the issues join' do
    in_range = make_issue(created_on: Date.new(2026, 7, 10).to_time)
    out_of_range = make_issue(created_on: Date.new(2026, 6, 1).to_time)
    make_result(in_range)
    make_result(out_of_range)

    scope = Sla::DashboardScope.call(project_ids: [1], date_range: Date.new(2026, 7, 1)..Date.new(2026, 7, 31))

    assert_equal [in_range.id], scope.pluck(:issue_id)
  end

  test 'combines project + tracker + priority + date filters with AND semantics' do
    matches_all = make_issue(project_id: 1, tracker_id: 1, priority_id: 4,
                             created_on: Date.new(2026, 7, 10).to_time)
    wrong_tracker = make_issue(project_id: 1, tracker_id: 2, priority_id: 4,
                               created_on: Date.new(2026, 7, 10).to_time)
    make_result(matches_all)
    make_result(wrong_tracker)

    scope = Sla::DashboardScope.call(project_ids: [1], tracker_ids: [1], priority_ids: [4],
                                     date_range: Date.new(2026, 7, 1)..Date.new(2026, 7, 31))

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
