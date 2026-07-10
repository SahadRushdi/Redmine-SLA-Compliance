# frozen_string_literal: true

require_relative '../../test_helper'

# Phase 2 · Step 2.3 — Business-hours elapsed calculation (highest-bug-risk component).
#
# Done when: "Tests cover spans crossing weekends, non-working hours, and holidays." Tested in
# isolation with a duck-typed calendar double (no DB) and an explicit UTC zone for the core
# logic, plus a DST-zone case to prove a weekend-crossing span is unaffected by a DST shift.
#
# Reference calendar unless noted: Mon–Fri (ISO 1–5), 09:00–17:00 (an 8h / 28_800s day).
class Sla::BusinessHoursCalculatorTest < ActiveSupport::TestCase
  # Duck-types SlaBusinessCalendar's readers without a DB row.
  Calendar = Struct.new(:working_days, :work_start_time, :work_end_time, :holidays,
                        keyword_init: true)

  UTC = ActiveSupport::TimeZone['UTC']
  NY  = ActiveSupport::TimeZone['America/New_York']

  # 2026-06-01 is a Monday, so the week 06-01..06-05 is Mon..Fri and 06-06/06-07 is the weekend.
  MON = 1
  TUE = 2
  WED = 3
  THU = 4
  FRI = 5
  SAT = 6
  SUN = 7

  def build(zone: UTC, working_days: [1, 2, 3, 4, 5], start: '09:00', finish: '17:00', holidays: [])
    cal = Calendar.new(working_days: working_days, work_start_time: start,
                       work_end_time: finish, holidays: holidays)
    Sla::BusinessHoursCalculator.new(cal, zone: zone)
  end

  # Helper: a June-2026 weekday/weekend timestamp. `dow` is the ISO day (MON..SUN) of that week.
  def t(dow, hour, min = 0, zone: UTC)
    zone.local(2026, 6, dow, hour, min)
  end

  # --- fully inside one working day -----------------------------------------------------

  test "span fully within a single working day" do
    assert_equal 18_000, build.elapsed(t(WED, 10), t(WED, 15)) # 5h
  end

  test "span wider than the window is clamped to the working window" do
    assert_equal 28_800, build.elapsed(t(WED, 8), t(WED, 18)) # full 8h day
  end

  # --- non-working hours contribute nothing ---------------------------------------------

  test "span entirely before the working window is zero" do
    assert_equal 0, build.elapsed(t(WED, 6), t(WED, 8))
  end

  test "span entirely after the working window is zero" do
    assert_equal 0, build.elapsed(t(WED, 18), t(WED, 20))
  end

  test "overnight span counts only each day's in-window portion" do
    # Wed 15:00->17:00 (2h) + Thu 09:00->11:00 (2h) = 4h; the closed overnight adds nothing.
    assert_equal 14_400, build.elapsed(t(WED, 15), t(THU, 11))
  end

  test "start day begins after the window, later day contributes" do
    # Wed after-hours (0) + Thu full (8h) + Fri 09:00->11:00 (2h) = 10h.
    assert_equal 36_000, build.elapsed(t(WED, 18), t(FRI, 11))
  end

  # --- weekends -------------------------------------------------------------------------

  test "span crossing a weekend skips Saturday and Sunday" do
    # Fri 15:00->17:00 (2h) + [Sat/Sun 0] + Mon 09:00->11:00 (2h) = 4h.
    assert_equal 14_400, build.elapsed(t(FRI, 15), t(MON + 7, 11))
  end

  test "span entirely on a weekend is zero" do
    assert_equal 0, build.elapsed(t(SAT, 10), t(SUN, 15))
  end

  # --- holidays -------------------------------------------------------------------------

  test "a holiday in the middle of the span contributes nothing" do
    # Make Thursday 2026-06-04 a holiday: Wed 15:00->17:00 (2h) + Thu(holiday 0) +
    # Fri 09:00->11:00 (2h) = 4h.
    calc = build(holidays: ['2026-06-04'])
    assert_equal 14_400, calc.elapsed(t(WED, 15), t(FRI, 11))
  end

  test "holidays accept Date objects as well as strings" do
    calc = build(holidays: [Date.new(2026, 6, 4)])
    assert_equal 14_400, calc.elapsed(t(WED, 15), t(FRI, 11))
  end

  test "a full working day that is a holiday yields zero" do
    calc = build(holidays: ['2026-06-03']) # Wednesday
    assert_equal 0, calc.elapsed(t(WED, 9), t(WED, 17))
  end

  # --- multi-day spans ------------------------------------------------------------------

  test "several whole working days sum to full days" do
    # Mon 09:00 -> Wed 17:00 = 3 full days * 8h = 24h.
    assert_equal 86_400, build.elapsed(t(MON, 9), t(WED, 17))
  end

  test "partial start, full middle, partial end" do
    # Mon 14:00->17:00 (3h) + Tue full (8h) + Wed 09:00->10:00 (1h) = 12h.
    assert_equal 43_200, build.elapsed(t(MON, 14), t(WED, 10))
  end

  # --- degenerate spans -----------------------------------------------------------------

  test "zero-length and reversed spans are zero" do
    assert_equal 0, build.elapsed(t(WED, 10), t(WED, 10))
    assert_equal 0, build.elapsed(t(WED, 15), t(WED, 10))
  end

  test "nil endpoints elapse zero" do
    assert_equal 0, build.elapsed(nil, t(WED, 10))
    assert_equal 0, build.elapsed(t(WED, 10), nil)
  end

  test "a calendar with no working window defined elapses zero" do
    calc = build(start: nil, finish: nil)
    assert_equal 0, calc.elapsed(t(WED, 9), t(WED, 17))
  end

  # --- custom calendars -----------------------------------------------------------------

  test "custom working days (Sun-Thu week) are honored" do
    # working_days = Sun(7), Mon(1)..Thu(4); Fri/Sat are non-working.
    calc = build(working_days: [7, 1, 2, 3, 4])
    assert_equal 0, calc.elapsed(t(FRI, 10), t(FRI, 16))          # Friday now non-working
    assert_equal 28_800, calc.elapsed(t(SUN, 8), t(SUN, 18))      # Sunday now a full working day
  end

  # --- DST across a weekend-crossing span (business-hours mode) --------------------------

  test "DST spring-forward on a non-working Sunday does not corrupt a weekend-crossing span" do
    # America/New_York springs forward Sun 2026-03-08. Fri 2026-03-06 -> Mon 2026-03-09:
    # Fri 15:00->17:00 (2h) + [Sat/Sun 0] + Mon 09:00->11:00 (2h) = 4h, unaffected by the shift.
    calc = build(zone: NY)
    from = NY.local(2026, 3, 6, 15, 0) # Friday
    to   = NY.local(2026, 3, 9, 11, 0) # Monday
    assert_equal 14_400, calc.elapsed(from, to)
  end
end
