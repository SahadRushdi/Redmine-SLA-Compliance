# frozen_string_literal: true

require_relative '../../test_helper'

# Phase 2 · Step 2.4 — Pause/exclusion handling.
#
# Done when: "Tests cover multiple pause intervals and a pause spanning a weekend (business-hours
# mode)." Timelines are built from the real Sla::TimelineBuilder value objects; the calculators
# are the real 2.2/2.3 services. No DB.
class Sla::PauseCalculatorTest < ActiveSupport::TestCase
  Event    = Sla::TimelineBuilder::Event
  Timeline = Sla::TimelineBuilder::Timeline
  Calendar = Struct.new(:working_days, :work_start_time, :work_end_time, :holidays,
                        keyword_init: true)

  OPEN   = 1
  PAUSED = 9

  setup do
    @zone     = ActiveSupport::TimeZone['UTC']
    @base     = @zone.local(2026, 6, 1, 9, 0, 0) # Monday
    @calendar = Sla::CalendarTimeCalculator.new
  end

  def at(hours)
    @base + hours * 3600
  end

  # Build a timeline: creation in OPEN plus [from_status, to_status, at] transitions.
  def timeline(changes, initial: OPEN)
    events = [Event.new(type: :created, at: @base, to_status_id: initial)]
    changes.each do |from, to, at|
      events << Event.new(type: :status_change, at: at, from_status_id: from, to_status_id: to)
    end
    Timeline.new(events.sort_by(&:at))
  end

  def calc(tl, pause_status_ids: [PAUSED], calculator: @calendar)
    Sla::PauseCalculator.new(tl, pause_status_ids: pause_status_ids, calculator: calculator)
  end

  # --- calendar mode --------------------------------------------------------------------

  test "single pause interval is subtracted" do
    tl = timeline([[OPEN, PAUSED, at(2)], [PAUSED, OPEN, at(4)]])
    assert_equal 7_200, calc(tl).paused_seconds(@base, at(6))          # 2h paused
    assert_equal 14_400, calc(tl).net_elapsed(@base, at(6))            # 6h - 2h
  end

  test "multiple pause intervals are summed" do
    tl = timeline([[OPEN, PAUSED, at(1)], [PAUSED, OPEN, at(2)],
                   [OPEN, PAUSED, at(4)], [PAUSED, OPEN, at(5)]])
    assert_equal 7_200, calc(tl).paused_seconds(@base, at(6))          # 1h + 1h
    assert_equal 14_400, calc(tl).net_elapsed(@base, at(6))            # 6h - 2h
  end

  test "a pause extending past the window end is clamped to the window" do
    tl = timeline([[OPEN, PAUSED, at(4)], [PAUSED, OPEN, at(8)]])
    assert_equal 7_200, calc(tl).paused_seconds(@base, at(6))          # only at(4)..at(6)
  end

  test "a still-open pause at the window end counts up to the window end" do
    tl = timeline([[OPEN, PAUSED, at(3)]])                             # never resumed
    assert_equal 10_800, calc(tl).paused_seconds(@base, at(6))         # at(3)..at(6) = 3h
  end

  test "a pause entirely outside the window contributes nothing" do
    tl = timeline([[OPEN, PAUSED, at(7)], [PAUSED, OPEN, at(8)]])
    assert_equal 0, calc(tl).paused_seconds(@base, at(6))
  end

  test "no pause statuses configured means nothing is subtracted" do
    tl = timeline([[OPEN, PAUSED, at(2)], [PAUSED, OPEN, at(4)]])
    pc = calc(tl, pause_status_ids: [])
    assert_equal 0, pc.paused_seconds(@base, at(6))
    assert_equal 21_600, pc.net_elapsed(@base, at(6))                  # full 6h
  end

  test "non-pause statuses are never subtracted" do
    tl = timeline([[OPEN, 2, at(2)], [2, OPEN, at(4)]])                # status 2 is not a pause
    assert_equal 0, calc(tl).paused_seconds(@base, at(6))
  end

  test "degenerate windows yield zero" do
    tl = timeline([[OPEN, PAUSED, at(2)], [PAUSED, OPEN, at(4)]])
    assert_equal 0, calc(tl).paused_seconds(at(6), at(6))
    assert_equal 0, calc(tl).paused_seconds(at(6), at(2))
    assert_equal 0, calc(tl).paused_seconds(nil, at(6))
  end

  # --- business-hours mode: pause spanning a weekend ------------------------------------

  test "a pause spanning a weekend subtracts only its working-hours portion" do
    zone     = ActiveSupport::TimeZone['UTC']
    business = Sla::BusinessHoursCalculator.new(
      Calendar.new(working_days: [1, 2, 3, 4, 5], work_start_time: '09:00',
                   work_end_time: '17:00', holidays: []),
      zone: zone
    )

    fri_09 = zone.local(2026, 6, 5, 9, 0)   # Friday 09:00
    fri_15 = zone.local(2026, 6, 5, 15, 0)  # pause begins
    mon_11 = zone.local(2026, 6, 8, 11, 0)  # pause ends (after the weekend)
    mon_17 = zone.local(2026, 6, 8, 17, 0)  # window end

    tl = timeline_from(fri_09, [[OPEN, PAUSED, fri_15], [PAUSED, OPEN, mon_11]])
    pc = Sla::PauseCalculator.new(tl, pause_status_ids: [PAUSED], calculator: business)

    # Pause working portion: Fri 15:00-17:00 (2h) + Mon 09:00-11:00 (2h) = 4h. The weekend
    # itself is not working time, so it was never counted.
    assert_equal 14_400, pc.paused_seconds(fri_09, mon_17)
    # Gross working time Fri 09-17 (8h) + Mon 09-17 (8h) = 16h; net = 16h - 4h = 12h.
    assert_equal 43_200, pc.net_elapsed(fri_09, mon_17)
  end

  # Variant builder for the business test that needs an explicit creation instant.
  def timeline_from(created_at, changes, initial: OPEN)
    events = [Event.new(type: :created, at: created_at, to_status_id: initial)]
    changes.each do |from, to, at|
      events << Event.new(type: :status_change, at: at, from_status_id: from, to_status_id: to)
    end
    Timeline.new(events.sort_by(&:at))
  end
end
