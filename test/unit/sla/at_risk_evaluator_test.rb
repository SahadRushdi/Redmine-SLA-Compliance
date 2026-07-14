# frozen_string_literal: true

require_relative '../../test_helper'

# Phase 2 · Step 2.7 — At-risk evaluation.
#
# Done when: "Tests cover on-track -> at-risk -> breached transitions for each target, in both
# calendar and business-hours modes." Exercises the flag and the projected breach_at directly.
class Sla::AtRiskEvaluatorTest < ActiveSupport::TestCase
  UTC      = ActiveSupport::TimeZone['UTC']
  Calendar = Struct.new(:working_days, :work_start_time, :work_end_time, :holidays,
                        keyword_init: true)

  def calendar_eval(threshold: 80, now: UTC.local(2026, 6, 1, 9, 0))
    Sla::AtRiskEvaluator.new(threshold_percent: threshold,
                             calculator: Sla::CalendarTimeCalculator.new, now: now)
  end

  def business_eval(now:, threshold: 80)
    cal = Sla::BusinessHoursCalculator.new(
      Calendar.new(working_days: [1, 2, 3, 4, 5], work_start_time: '09:00',
                   work_end_time: '17:00', holidays: []), zone: UTC
    )
    Sla::AtRiskEvaluator.new(threshold_percent: threshold, calculator: cal, now: now)
  end

  # --- calendar mode: on-track -> at-risk -> breached -----------------------------------

  test "calendar: on-track ticket is not at risk and projects a future breach" do
    now = UTC.local(2026, 6, 1, 9, 0)
    at_risk, breach_at = calendar_eval(now: now).evaluate([{ target: 3600, elapsed: 1800 }])
    refute at_risk
    assert_equal now + 1800, breach_at # remaining 1800s
  end

  test "calendar: exactly at the threshold flags at risk" do
    at_risk, = calendar_eval.evaluate([{ target: 3600, elapsed: 2880 }]) # 80%
    assert at_risk
  end

  test "calendar: between threshold and target is at risk" do
    at_risk, = calendar_eval.evaluate([{ target: 3600, elapsed: 3200 }])
    assert at_risk
  end

  test "calendar: a breached milestone is neither at risk nor projected" do
    at_risk, breach_at = calendar_eval.evaluate([{ target: 3600, elapsed: 3700 }])
    refute at_risk
    assert_nil breach_at
  end

  # --- multiple targets: any one crossing flags, earliest breach wins -------------------

  test "at risk if ANY pending target crosses the threshold; breach_at is the earliest" do
    now = UTC.local(2026, 6, 1, 9, 0)
    milestones = [{ target: 3600, elapsed: 100 },    # on-track (remaining 3500)
                  { target: 7200, elapsed: 6000 }]   # 83% -> at risk (remaining 1200)
    at_risk, breach_at = calendar_eval(now: now).evaluate(milestones)
    assert at_risk
    assert_equal now + 1200, breach_at
  end

  test "no pending milestones means not at risk and no breach_at" do
    at_risk, breach_at = calendar_eval.evaluate([])
    refute at_risk
    assert_nil breach_at
  end

  # --- business-hours mode --------------------------------------------------------------

  test "business: on-track ticket projects breach_at in working time" do
    now = UTC.local(2026, 6, 3, 10, 0) # Wed 10:00
    at_risk, breach_at = business_eval(now: now).evaluate([{ target: 14_400, elapsed: 3600 }])
    refute at_risk # 25%
    assert_equal UTC.local(2026, 6, 3, 13, 0), breach_at # +3h working
  end

  test "business: crossing the threshold flags at risk" do
    now = UTC.local(2026, 6, 3, 10, 0)
    at_risk, = business_eval(now: now).evaluate([{ target: 14_400, elapsed: 12_000 }]) # 83%
    assert at_risk
  end

  test "business: a breached milestone is neither at risk nor projected" do
    now = UTC.local(2026, 6, 3, 10, 0)
    at_risk, breach_at = business_eval(now: now).evaluate([{ target: 14_400, elapsed: 15_000 }])
    refute at_risk
    assert_nil breach_at
  end

  test "business: breach projection rolls into the next working day" do
    now = UTC.local(2026, 6, 3, 16, 0) # Wed 16:00, 1h to close
    # remaining 10800s (3h): Wed 16:00-17:00 (1h) + Thu 09:00-11:00 (2h) = Thu 11:00.
    _, breach_at = business_eval(now: now).evaluate([{ target: 14_400, elapsed: 3600 }])
    assert_equal UTC.local(2026, 6, 4, 11, 0), breach_at
  end
end
