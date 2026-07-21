# frozen_string_literal: true

require_relative '../../test_helper'

# Step 6.3 — Sla::TrendSeries: Created-vs-Resolved trend series (dual line, Daily/Weekly/Monthly)
# for the dashboard's trend chart, bucketed in Ruby over sla_results/issues (Global Rule 4).
class Sla::TrendSeriesTest < ActiveSupport::TestCase
  fixtures :projects, :trackers, :projects_trackers, :issue_statuses, :enumerations, :users,
           :email_addresses, :roles, :members, :member_roles

  # Issue#force_updated_on_change unconditionally stamps created_on to "now" on create, so passing
  # created_on: to Issue.generate! is silently clobbered - update_column after the fact (bypassing
  # callbacks) is the established pattern for this elsewhere in the plugin's test suite (see e.g.
  # dashboard_scope_test.rb, timeline_builder_test.rb).
  def make_issue(project_id: 1, tracker_id: 1, priority_id: 4, created_on:)
    issue = Issue.generate!(project: Project.find(project_id), tracker_id: tracker_id, priority_id: priority_id)
    issue.update_column(:created_on, created_on)
    issue
  end

  def make_result(issue, resolved_at: nil)
    SlaResult.create!(issue_id: issue.id, project_id: issue.project_id, primary_state: 'met',
                      resolved_at: resolved_at)
  end

  def scope(project_ids: [1])
    Sla::DashboardScope.call(project_ids: project_ids)
  end

  test "buckets Created and Resolved counts by day when granularity is daily" do
    date_range = Date.new(2026, 7, 1)..Date.new(2026, 7, 3)
    issue_a = make_issue(created_on: Time.zone.local(2026, 7, 1, 9))
    issue_b = make_issue(created_on: Time.zone.local(2026, 7, 1, 15))
    issue_c = make_issue(created_on: Time.zone.local(2026, 7, 3, 8))
    make_result(issue_a, resolved_at: Time.zone.local(2026, 7, 2, 10))
    make_result(issue_b)
    make_result(issue_c)

    points = Sla::TrendSeries.call(scope: scope, date_range: date_range, granularity: 'daily')

    assert_equal [Date.new(2026, 7, 1), Date.new(2026, 7, 2), Date.new(2026, 7, 3)], points.map(&:bucket_start)
    assert_equal [2, 0, 1], points.map(&:created)
    assert_equal [0, 1, 0], points.map(&:resolved)
  end

  test "zero-fills buckets with no activity rather than omitting them" do
    date_range = Date.new(2026, 7, 1)..Date.new(2026, 7, 5)
    issue = make_issue(created_on: Time.zone.local(2026, 7, 1, 9))
    make_result(issue) # resolved_at nil - resolved stays 0 everywhere

    points = Sla::TrendSeries.call(scope: scope, date_range: date_range, granularity: 'daily')

    assert_equal 5, points.size
    assert_equal [1, 0, 0, 0, 0], points.map(&:created)
    assert_equal [0, 0, 0, 0, 0], points.map(&:resolved)
  end

  test "an issue created outside date_range but resolved inside it still counts on the Resolved line" do
    date_range = Date.new(2026, 7, 10)..Date.new(2026, 7, 14)
    old_issue = make_issue(created_on: Time.zone.local(2026, 6, 1, 9))
    make_result(old_issue, resolved_at: Time.zone.local(2026, 7, 12, 10))

    points = Sla::TrendSeries.call(scope: scope, date_range: date_range, granularity: 'daily')

    assert_equal [0, 0, 0, 0, 0], points.map(&:created), 'created outside the window must not appear'
    assert_equal [0, 0, 1, 0, 0], points.map(&:resolved)
  end

  test "rows with a nil resolved_at are excluded from the Resolved line" do
    date_range = Date.new(2026, 7, 1)..Date.new(2026, 7, 1)
    issue = make_issue(created_on: Time.zone.local(2026, 7, 1, 9))
    make_result(issue, resolved_at: nil)

    points = Sla::TrendSeries.call(scope: scope, date_range: date_range, granularity: 'daily')

    assert_equal [1], points.map(&:created)
    assert_equal [0], points.map(&:resolved)
  end

  test "weekly granularity buckets by the same beginning_of_week semantics used elsewhere on the dashboard" do
    week1_start = Date.new(2026, 7, 1).beginning_of_week
    week2_start = week1_start + 7
    date_range = week1_start..(week2_start + 6) # exactly two full weeks, aligned to bucket boundaries

    issue_a = make_issue(created_on: Time.zone.local(week1_start.year, week1_start.month, week1_start.day, 9))
    issue_b = make_issue(created_on: Time.zone.local(week1_start.year, week1_start.month, week1_start.day, 9) + 3.days)
    issue_c = make_issue(created_on: Time.zone.local(week2_start.year, week2_start.month, week2_start.day, 9))
    [issue_a, issue_b, issue_c].each { |issue| make_result(issue) }

    points = Sla::TrendSeries.call(scope: scope, date_range: date_range, granularity: 'weekly')

    week1 = points.find { |p| p.bucket_start == week1_start }
    week2 = points.find { |p| p.bucket_start == week2_start }
    assert_equal 2, week1.created
    assert_equal 1, week2.created
  end

  test "monthly granularity buckets by calendar month" do
    date_range = Date.new(2026, 6, 1)..Date.new(2026, 8, 31)
    [Time.zone.local(2026, 6, 15, 9), Time.zone.local(2026, 6, 20, 9), Time.zone.local(2026, 7, 5, 9)].each do |created_on|
      make_result(make_issue(created_on: created_on))
    end

    points = Sla::TrendSeries.call(scope: scope, date_range: date_range, granularity: 'monthly')

    june   = points.find { |p| p.bucket_start == Date.new(2026, 6, 1) }
    july   = points.find { |p| p.bucket_start == Date.new(2026, 7, 1) }
    august = points.find { |p| p.bucket_start == Date.new(2026, 8, 1) }
    assert_equal 2, june.created
    assert_equal 1, july.created
    assert_equal 0, august.created
  end

  test "an unrecognized granularity falls back to daily rather than raising" do
    date_range = Date.new(2026, 7, 1)..Date.new(2026, 7, 1)
    make_issue(created_on: Time.zone.local(2026, 7, 1, 9))

    points = Sla::TrendSeries.call(scope: scope, date_range: date_range, granularity: 'yearly')

    assert_equal 1, points.size
    assert_equal Date.new(2026, 7, 1), points.first.bucket_start
  end

  test "a nil date_range returns an empty array rather than raising" do
    points = Sla::TrendSeries.call(scope: scope, date_range: nil)

    assert_equal [], points
  end
end
