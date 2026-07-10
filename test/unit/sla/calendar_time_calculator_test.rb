# frozen_string_literal: true

require_relative '../../test_helper'

# Phase 2 · Step 2.2 — Calendar-time elapsed calculation.
#
# Verifies the absolute wall-clock duration between two instants, exercised across day, month,
# year and DST boundaries (Done when: "Tested across day/month/DST boundaries"). Uses explicit
# time zones so the assertions do not depend on the host's Time.zone. No DB involved.
class Sla::CalendarTimeCalculatorTest < ActiveSupport::TestCase
  # US DST in 2026: spring forward Sun 2026-03-08 02:00 -> 03:00; fall back Sun 2026-11-01
  # 02:00 -> 01:00.
  NY  = ActiveSupport::TimeZone['America/New_York']
  UTC = ActiveSupport::TimeZone['UTC']

  setup { @calc = Sla::CalendarTimeCalculator.new }

  test "identical instants elapse zero" do
    t = UTC.local(2026, 6, 1, 9, 0, 0)
    assert_equal 0, @calc.elapsed(t, t)
  end

  test "a reversed span (to before from) is clamped to zero" do
    from = UTC.local(2026, 6, 1, 11, 0, 0)
    to   = UTC.local(2026, 6, 1, 9, 0, 0)
    assert_equal 0, @calc.elapsed(from, to)
  end

  test "nil endpoints elapse zero" do
    assert_equal 0, @calc.elapsed(nil, UTC.local(2026, 6, 1, 9))
    assert_equal 0, @calc.elapsed(UTC.local(2026, 6, 1, 9), nil)
  end

  test "simple intra-day span" do
    from = UTC.local(2026, 6, 1, 9, 0, 0)
    to   = UTC.local(2026, 6, 1, 11, 30, 0)
    assert_equal 9_000, @calc.elapsed(from, to) # 2h30m
  end

  test "span crossing a day boundary" do
    from = UTC.local(2026, 6, 1, 23, 0, 0)
    to   = UTC.local(2026, 6, 2, 1, 0, 0)
    assert_equal 7_200, @calc.elapsed(from, to) # 2h across midnight
  end

  test "span crossing a month boundary" do
    from = UTC.local(2026, 1, 31, 23, 0, 0)
    to   = UTC.local(2026, 2, 1, 1, 0, 0)
    assert_equal 7_200, @calc.elapsed(from, to)
  end

  test "span crossing a year boundary" do
    from = UTC.local(2026, 12, 31, 23, 30, 0)
    to   = UTC.local(2027, 1, 1, 0, 30, 0)
    assert_equal 3_600, @calc.elapsed(from, to)
  end

  test "DST spring-forward: 01:30 to 03:30 local is one real hour" do
    # 02:00 does not exist; wall clock shows 2h but only 3600 real seconds pass.
    from = NY.local(2026, 3, 8, 1, 30, 0)
    to   = NY.local(2026, 3, 8, 3, 30, 0)
    assert_equal 3_600, @calc.elapsed(from, to)
  end

  test "DST fall-back: 00:30 to 02:30 local is three real hours" do
    # The 01:00 hour occurs twice; wall clock shows 2h but 10800 real seconds pass.
    from = NY.local(2026, 11, 1, 0, 30, 0)
    to   = NY.local(2026, 11, 1, 2, 30, 0)
    assert_equal 10_800, @calc.elapsed(from, to)
  end

  test "mixed input zones compare by absolute instant" do
    # Same instant expressed in two zones -> zero elapsed.
    utc_noon = UTC.local(2026, 6, 1, 16, 0, 0)   # 16:00 UTC
    ny_noon  = NY.local(2026, 6, 1, 12, 0, 0)    # 12:00 EDT == 16:00 UTC
    assert_equal 0, @calc.elapsed(utc_noon, ny_noon)
  end
end
