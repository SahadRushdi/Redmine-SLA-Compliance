# frozen_string_literal: true

require_relative '../../test_helper'

# Phase 2 · Step 2.8 — Stale-ticket detection.
#
# Done when: "Tests return correct inactivity durations from fixtures." Timelines are built from
# the real Sla::TimelineBuilder value objects; no DB.
class Sla::StaleTicketDetectorTest < ActiveSupport::TestCase
  Event    = Sla::TimelineBuilder::Event
  Timeline = Sla::TimelineBuilder::Timeline
  UTC      = ActiveSupport::TimeZone['UTC']

  setup do
    @base = UTC.local(2026, 6, 1, 9, 0, 0)
    @now  = UTC.local(2026, 6, 10, 9, 0, 0) # 9 days later
  end

  def timeline(*events)
    created = Event.new(type: :created, at: @base, to_status_id: 1)
    Timeline.new(([created] + events).sort_by(&:at))
  end

  def comment(at, private: false)
    Event.new(type: :comment, at: at, private_note: private)
  end

  def status_change(at)
    Event.new(type: :status_change, at: at, from_status_id: 1, to_status_id: 2)
  end

  def detector(tl)
    Sla::StaleTicketDetector.new(tl, now: @now)
  end

  test "with no activity, inactivity is measured from creation" do
    d = detector(timeline)
    assert_equal @base, d.last_activity_at
    assert_equal 777_600, d.inactive_seconds # 9 days
  end

  test "last activity is the most recent comment or status change" do
    d = detector(timeline(comment(@base + 3600), status_change(@base + 7200)))
    assert_equal @base + 7200, d.last_activity_at
    assert_equal @now.to_i - (@base + 7200).to_i, d.inactive_seconds
  end

  test "a private note still counts as activity" do
    d = detector(timeline(comment(@base + 5000, private: true)))
    assert_equal @base + 5000, d.last_activity_at
  end

  test "a comment earlier than a status change does not override the later one" do
    d = detector(timeline(status_change(@base + 9000), comment(@base + 1000)))
    assert_equal @base + 9000, d.last_activity_at
  end

  test "stale? compares inactivity against the threshold (boundary inclusive)" do
    d = detector(timeline(comment(@base + 3600)))
    inactive = @now.to_i - (@base + 3600).to_i
    assert d.stale?(inactive - 1)
    assert d.stale?(inactive)
    refute d.stale?(inactive + 1)
  end
end
