# frozen_string_literal: true

require_relative '../../test_helper'

# Sla::StaleSummary — the dashboard "Stale" card count: OPEN sla_results-scoped tickets with no
# updates (issues.updated_on) past their project's inactivity threshold. Like DashboardScope, every
# assertion has to prove the count reaches through the `issues` join (updated_on/closed_on live on
# issues, not sla_results). Runs inside Redmine's transactional tests — nothing persists.
class Sla::StaleSummaryTest < ActiveSupport::TestCase
  fixtures :projects, :trackers, :projects_trackers, :issue_statuses, :enumerations, :users,
           :email_addresses, :roles, :members, :member_roles

  NOW = Time.zone.local(2026, 7, 15, 12, 0, 0)

  def make_issue(project_id: 1, updated_on: NOW, closed_on: nil)
    issue = Issue.generate!(project: Project.find(project_id), tracker_id: 1, priority_id: 4)
    issue.update_columns(updated_on: updated_on, closed_on: closed_on)
    issue
  end

  def make_result(issue)
    SlaResult.create!(issue_id: issue.id, project_id: issue.project_id,
                      primary_state: 'no_sla', no_sla_reason: 'not_tracked')
  end

  def count_for(*issues)
    Sla::StaleSummary.call(scope: SlaResult.where(issue_id: issues.map(&:id)), now: NOW)
  end

  test 'counts open tickets idle past the default 7-day threshold, and only those' do
    stale = make_issue(updated_on: NOW - 10.days)
    fresh = make_issue(updated_on: NOW - 2.days)
    make_result(stale)
    make_result(fresh)

    assert_equal 1, count_for(stale, fresh)
  end

  test 'a closed ticket is never stale, however long it has sat untouched' do
    closed = make_issue(updated_on: NOW - 30.days, closed_on: NOW - 20.days)
    make_result(closed)

    assert_equal 0, count_for(closed)
  end

  test 'the boundary is inclusive of the threshold: exactly 7 days idle counts as stale' do
    at_threshold = make_issue(updated_on: NOW - 7.days)
    make_result(at_threshold)

    assert_equal 1, count_for(at_threshold)
  end

  test "uses the project's configured threshold, not the default" do
    SlaNotificationSetting.create!(project_id: 1, stale_threshold_days: 3,
                                   at_risk_email_frequency: 'realtime', stale_email_frequency: 'weekly')
    idle_four_days = make_issue(updated_on: NOW - 4.days)
    make_result(idle_four_days)

    # Idle 4 days: not stale under the default 7, but stale under this project's 3-day threshold.
    assert_equal 1, count_for(idle_four_days)
  end

  test 'an empty scope returns zero without error' do
    assert_equal 0, Sla::StaleSummary.call(scope: SlaResult.where(issue_id: []), now: NOW)
  end
end
