# frozen_string_literal: true

require_relative '../../test_helper'

# Step 6.3 — Sla::TrendSeries: Created-vs-Resolved counts bucketed by day/week/month, all three
# returned from one call so the dashboard's granularity toggle needs no extra query.
class Sla::TrendSeriesTest < ActiveSupport::TestCase
  fixtures :projects, :trackers, :projects_trackers, :issue_statuses, :enumerations, :users,
           :email_addresses, :roles, :members, :member_roles

  def make_issue(created_on:, project_id: 1, tracker_id: 1, priority_id: 4)
    issue = Issue.generate!(project: Project.find(project_id), tracker_id: tracker_id, priority_id: priority_id)
    issue.update_column(:created_on, created_on)
    issue
  end

  def make_result(issue, resolved_at: nil)
    SlaResult.create!(issue_id: issue.id, project_id: issue.project_id, primary_state: resolved_at ? 'met' : 'met',
                      resolved_at: resolved_at)
  end

  def scope
    Sla::DashboardScope.call(project_ids: [1])
  end

  test "buckets two tickets created on the same day into one daily point" do
    a = make_issue(created_on: Time.zone.local(2026, 7, 15, 9, 0))
    b = make_issue(created_on: Time.zone.local(2026, 7, 15, 17, 0))
    make_result(a)
    make_result(b)

    series = Sla::TrendSeries.call(scope: scope, date_range: Date.new(2026, 7, 1)..Date.new(2026, 7, 31))
    point = series.daily.find { |p| p.label == 'Jul 15' }

    assert_equal 2, point.created
  end

  test "a week boundary correctly separates a Sunday-created ticket from a Monday-created ticket" do
    sunday = make_issue(created_on: Time.zone.local(2026, 7, 12, 12, 0)) # week of Jul 6
    monday = make_issue(created_on: Time.zone.local(2026, 7, 13, 12, 0)) # week of Jul 13
    make_result(sunday)
    make_result(monday)

    series = Sla::TrendSeries.call(scope: scope, date_range: Date.new(2026, 7, 1)..Date.new(2026, 7, 31))
    week_of_6  = series.weekly.find { |p| p.label == 'Jul 6' }
    week_of_13 = series.weekly.find { |p| p.label == 'Jul 13' }

    assert_equal 1, week_of_6.created
    assert_equal 1, week_of_13.created
  end

  test "a ticket created on the last day of a month and one on the first day of the next land in different monthly buckets" do
    end_of_july   = make_issue(created_on: Time.zone.local(2026, 7, 31, 12, 0))
    start_of_august = make_issue(created_on: Time.zone.local(2026, 8, 1, 12, 0))
    make_result(end_of_july)
    make_result(start_of_august)

    series = Sla::TrendSeries.call(scope: scope, date_range: Date.new(2026, 7, 1)..Date.new(2026, 8, 31))
    july   = series.monthly.find { |p| p.label == 'Jul 2026' }
    august = series.monthly.find { |p| p.label == 'Aug 2026' }

    assert_equal 1, july.created
    assert_equal 1, august.created
  end

  test "resolved counts are bucketed by resolved_at, independent of the ticket's own created bucket" do
    issue = make_issue(created_on: Time.zone.local(2026, 7, 1, 9, 0))
    make_result(issue, resolved_at: Time.zone.local(2026, 7, 20, 9, 0))

    series = Sla::TrendSeries.call(scope: scope, date_range: Date.new(2026, 7, 1)..Date.new(2026, 7, 31))
    created_point  = series.daily.find { |p| p.label == 'Jul 1' }
    resolved_point = series.daily.find { |p| p.label == 'Jul 20' }

    assert_equal 1, created_point.created
    assert_equal 0, created_point.resolved
    assert_equal 1, resolved_point.resolved
    assert_equal 0, resolved_point.created
  end

  test "a ticket resolved after the filtered date_range does not appear in the Resolved series for this call" do
    issue = make_issue(created_on: Time.zone.local(2026, 7, 15, 9, 0))
    make_result(issue, resolved_at: Time.zone.local(2026, 8, 5, 9, 0)) # outside the July window

    series = Sla::TrendSeries.call(scope: scope, date_range: Date.new(2026, 7, 1)..Date.new(2026, 7, 31))

    assert_equal 0, series.daily.sum(&:resolved)
    assert_equal 1, series.daily.sum(&:created)
  end

  test "an unresolved ticket contributes to Created but never to Resolved in any bucket" do
    issue = make_issue(created_on: Time.zone.local(2026, 7, 15, 9, 0))
    make_result(issue, resolved_at: nil)

    series = Sla::TrendSeries.call(scope: scope, date_range: Date.new(2026, 7, 1)..Date.new(2026, 7, 31))

    assert_equal 1, series.daily.sum(&:created)
    assert_equal 0, series.daily.sum(&:resolved)
  end

  test "daily/weekly/monthly totals are returned together from one call, with no additional query needed to switch granularity" do
    issue = make_issue(created_on: Time.zone.local(2026, 7, 15, 9, 0))
    make_result(issue)

    series = Sla::TrendSeries.call(scope: scope, date_range: Date.new(2026, 7, 1)..Date.new(2026, 7, 31))

    assert_equal 1, series.daily.sum(&:created)
    assert_equal 1, series.weekly.sum(&:created)
    assert_equal 1, series.monthly.sum(&:created)
  end

  test "a nil date_range returns empty series rather than raising" do
    series = Sla::TrendSeries.call(scope: scope, date_range: nil)

    assert_equal [], series.daily
    assert_equal [], series.weekly
    assert_equal [], series.monthly
  end
end
