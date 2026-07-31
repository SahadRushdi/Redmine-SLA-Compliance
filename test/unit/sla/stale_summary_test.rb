# frozen_string_literal: true

require_relative '../../test_helper'

# Sla::StaleSummary — the dashboard "Stale" card: OPEN sla_results-scoped tickets with no updates
# (issues.updated_on) past their PROJECT'S configured inactivity threshold, inherited down the tree
# (Step 6.2a). Like DashboardScope, every assertion has to prove the count reaches through the
# `issues` join (updated_on lives on issues, not sla_results). Runs inside Redmine's transactional
# tests — nothing persists.
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

  # Thresholds injected per project: there is no built-in default to fall back on, which is the
  # point. `1` is the project every make_issue below belongs to unless told otherwise.
  def summary_for(*issues, thresholds: { 1 => 7 })
    Sla::StaleSummary.call(scope: SlaResult.where(issue_id: issues.map(&:id)), now: NOW,
                           thresholds: thresholds)
  end

  def count_for(*issues, **kwargs)
    summary_for(*issues, **kwargs).count
  end

  test 'counts open tickets idle past the configured threshold, and only those' do
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

  test 'the boundary is inclusive of the threshold: exactly N days idle counts as stale' do
    at_threshold = make_issue(updated_on: NOW - 7.days)
    make_result(at_threshold)

    assert_equal 1, count_for(at_threshold)
  end

  test 'the configured threshold is what decides, not a built-in number' do
    idle_four_days = make_issue(updated_on: NOW - 4.days)
    make_result(idle_four_days)

    assert_equal 0, count_for(idle_four_days, thresholds: { 1 => 7 })
    assert_equal 1, count_for(idle_four_days, thresholds: { 1 => 3 })
  end

  # The reason the per-project OR-of-cutoffs query exists: one dashboard scope, two projects, two
  # different rulers. A single global cutoff would have to be wrong for one of them.
  test 'each project in a multi-project scope is measured against its own threshold' do
    lenient = make_issue(project_id: 1, updated_on: NOW - 4.days) # threshold 7 -> not stale
    strict  = make_issue(project_id: 2, updated_on: NOW - 4.days) # threshold 3 -> stale
    make_result(lenient)
    make_result(strict)

    assert_equal 1, count_for(lenient, strict, thresholds: { 1 => 7, 2 => 3 })
  end

  test 'a project with no threshold contributes nothing, while its neighbours still count' do
    unconfigured = make_issue(project_id: 1, updated_on: NOW - 400.days)
    configured   = make_issue(project_id: 2, updated_on: NOW - 4.days)
    make_result(unconfigured)
    make_result(configured)

    summary = summary_for(unconfigured, configured, thresholds: { 2 => 3 })
    assert summary.configured?, 'a threshold applies somewhere in scope'
    assert_equal 1, summary.count, 'only the project that has one is measured'
  end

  # The whole reason the threshold has no default: an unconfigured instance must not have a number
  # invented for it. "Nobody has said what stale means here" is not "these tickets are stale".
  test 'with no threshold anywhere in scope the result is unconfigured, not zero stale tickets' do
    ancient = make_issue(updated_on: NOW - 400.days)
    make_result(ancient)

    summary = summary_for(ancient, thresholds: {})
    refute summary.configured?, '"nobody defined stale" is not "nothing is stale"'
    assert_equal 0, summary.count
  end

  test 'the thresholds are resolved from the projects in scope when the caller passes none' do
    idle_four_days = make_issue(updated_on: NOW - 4.days)
    make_result(idle_four_days)
    scope = SlaResult.where(issue_id: idle_four_days.id)

    refute Sla::StaleSummary.call(scope: scope, now: NOW).configured?, 'no project has one yet'

    SlaPolicy.create!(project_id: 1, enabled: true, stale_threshold_days: 2)
    assert_equal 1, Sla::StaleSummary.call(scope: scope, now: NOW).count
  end

  # The per-project field drives the stale-ticket EMAIL DIGEST (Step 8.3) and nothing else. The card
  # is cross-project, so mixing per-project rulers into one total was never a number that meant
  # anything.
  test "the notification digest's own threshold does not move the dashboard card" do
    SlaNotificationSetting.create!(project_id: 1, stale_threshold_days: 3,
                                   at_risk_email_frequency: 'realtime', stale_email_frequency: 'weekly')
    idle_four_days = make_issue(updated_on: NOW - 4.days)
    make_result(idle_four_days)

    assert_equal 0, count_for(idle_four_days, thresholds: { 1 => 7 }),
                 "the SLA policy's threshold decides the card; the digest field is the digest's"
  end

  test 'an empty scope returns an unconfigured zero without error' do
    summary = Sla::StaleSummary.call(scope: SlaResult.where(issue_id: []), now: NOW)
    assert_equal 0, summary.count
    refute summary.configured?
  end
end
