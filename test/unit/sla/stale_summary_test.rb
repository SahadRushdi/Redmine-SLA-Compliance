# frozen_string_literal: true

require_relative '../../test_helper'

# Sla::StaleSummary — the dashboard "Stale" card count: OPEN sla_results-scoped tickets with no
# updates (issues.updated_on) past their project's inactivity threshold. Like DashboardScope, every
# assertion has to prove the count reaches through the `issues` join (updated_on lives on issues,
# not sla_results). Runs inside Redmine's transactional tests — nothing persists.
class Sla::StaleSummaryTest < ActiveSupport::TestCase
  fixtures :projects, :trackers, :projects_trackers, :issue_statuses, :enumerations, :users,
           :email_addresses, :roles, :members, :member_roles

  NOW = Time.zone.local(2026, 7, 15, 12, 0, 0)

  def make_issue(project_id: 1, updated_on: NOW)
    issue = Issue.generate!(project: Project.find(project_id), tracker_id: 1, priority_id: 4)
    issue.update_columns(updated_on: updated_on)
    issue
  end

  # `resolved_at` is what makes a cached row open or not — the engine's own resolved-role
  # milestone, not issues.closed_on (see Sla::ResultClassifier#closed_at).
  def make_result(issue, resolved_at: nil)
    SlaResult.create!(issue_id: issue.id, project_id: issue.project_id,
                      primary_state: 'no_sla', no_sla_reason: 'not_tracked',
                      resolved_at: resolved_at)
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

  test 'a resolved ticket is never stale, however long it has sat untouched' do
    resolved = make_issue(updated_on: NOW - 30.days)
    make_result(resolved, resolved_at: NOW - 20.days)

    assert_equal 0, count_for(resolved)
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
