# frozen_string_literal: true

require_relative '../../test_helper'

# Phase 2 · Step 2.7 — At-risk evaluation.
#
# Exercises the flag and projected breach timestamps for the plugin's current 24x7 coverage mode.
class Sla::AtRiskEvaluatorTest < ActiveSupport::TestCase
  UTC = ActiveSupport::TimeZone['UTC']

  def calendar_eval(threshold: 80, now: UTC.local(2026, 6, 1, 9, 0))
    Sla::AtRiskEvaluator.new(threshold_percent: threshold,
                             calculator: Sla::CalendarTimeCalculator.new, now: now)
  end

  # --- calendar mode: on-track -> at-risk -> breached -----------------------------------

  test "calendar: on-track ticket is not at risk and projects a future breach" do
    now = UTC.local(2026, 6, 1, 9, 0)
    at_risk, breach_at, _kind, at_risk_at = calendar_eval(now: now).evaluate([{ target: 3600, elapsed: 1800 }])
    refute at_risk
    assert_equal now + 1800, breach_at # remaining 1800s
    assert_equal now + 1080, at_risk_at # another 30% until the 80% threshold
  end

  test "calendar: exactly at the threshold flags at risk" do
    now = UTC.local(2026, 6, 1, 9, 0)
    at_risk, _breach_at, _kind, at_risk_at = calendar_eval(now: now).evaluate([{ target: 3600, elapsed: 2880 }]) # 80%
    assert at_risk
    assert_equal now, at_risk_at
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

  # --- which target is at risk (the notification dedup key, Step 8.2) -------------------------

  test "reports the flagged milestone closest to breaching, agreeing with breach_at" do
    now = UTC.local(2026, 6, 1, 9, 0)
    milestones = [{ kind: :response, target: 3600, elapsed: 3000 },       # at risk, remaining 600
                  { kind: :resolution, target: 36_000, elapsed: 30_000 }] # at risk, remaining 6000
    at_risk, breach_at, kind = calendar_eval(now: now).evaluate(milestones)

    assert at_risk
    assert_equal :response, kind, 'the one breach_at projects is the one to notify about'
    assert_equal now + 600, breach_at
  end

  test "an on-track milestone is never reported as the at-risk target" do
    milestones = [{ kind: :response, target: 3600, elapsed: 100 },        # on track
                  { kind: :update_frequency, target: 7200, elapsed: 6000 }] # 83% -> at risk
    at_risk, _breach_at, kind = calendar_eval.evaluate(milestones)

    assert at_risk
    assert_equal :update_frequency, kind
  end

  test "no at-risk target when nothing crosses the threshold" do
    _at_risk, _breach_at, kind = calendar_eval.evaluate([{ kind: :response, target: 3600, elapsed: 100 }])
    assert_nil kind
  end

  test "a breached milestone is not reported as at-risk target either" do
    _at_risk, _breach_at, kind = calendar_eval.evaluate([{ kind: :resolution, target: 3600, elapsed: 9999 }])
    assert_nil kind
  end

end
