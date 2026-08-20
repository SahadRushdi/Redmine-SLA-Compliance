# frozen_string_literal: true

require_relative '../../test_helper'

# Sla::EffectiveState — the shared live-reclassification predicate every reader of the sla_results
# cache (ResultSummary, PriorityBreakdown, the dashboard detail table) must agree on. Tested here
# directly against a bare (unsaved) SlaResult instance — no database, no controller, no service.
class Sla::EffectiveStateTest < ActiveSupport::TestCase
  NOW = Time.zone.local(2026, 7, 15, 12, 0, 0)

  def result(primary_state:, breach_at: nil, at_risk_at: nil, at_risk: false, no_sla_reason: nil,
             deviation_seconds: nil, deviation_at: nil)
    SlaResult.new(primary_state: primary_state, breach_at: breach_at, at_risk_at: at_risk_at, at_risk: at_risk,
                  no_sla_reason: no_sla_reason, deviation_seconds: deviation_seconds,
                  deviation_at: deviation_at)
  end

  test "effective_primary_state returns breached for a persisted breached row regardless of breach_at" do
    r = result(primary_state: 'breached', breach_at: NOW + 1.hour) # a stray/impossible value
    assert_equal 'breached', r.effective_primary_state(NOW)
  end

  test "effective_primary_state returns met for a met row with breach_at still in the future" do
    r = result(primary_state: 'met', breach_at: NOW + 1.hour)
    assert_equal 'met', r.effective_primary_state(NOW)
  end

  test "effective_primary_state returns breached for a met row whose breach_at has already passed" do
    r = result(primary_state: 'met', breach_at: NOW - 1.minute)
    assert_equal 'breached', r.effective_primary_state(NOW)
  end

  test "effective_primary_state returns met for a met row with no breach_at (resolved within target)" do
    r = result(primary_state: 'met', breach_at: nil)
    assert_equal 'met', r.effective_primary_state(NOW)
  end

  test "effective_primary_state returns no_sla for a no_sla row even if breach_at happens to be set" do
    r = result(primary_state: 'no_sla', breach_at: NOW - 1.minute, no_sla_reason: 'not_tracked')
    assert_equal 'no_sla', r.effective_primary_state(NOW)
  end

  test "effective_at_risk? is true only when at_risk is set AND the row is still effectively met" do
    r = result(primary_state: 'met', breach_at: NOW + 1.hour, at_risk: true)
    assert r.effective_at_risk?(NOW)
  end

  test "effective_at_risk? is false when at_risk is not set" do
    r = result(primary_state: 'met', breach_at: NOW + 1.hour, at_risk: false)
    refute r.effective_at_risk?(NOW)
  end

  test "effective_at_risk? becomes true live when at_risk_at is reached" do
    r = result(primary_state: 'met', breach_at: NOW + 1.hour,
               at_risk_at: NOW - 1.second, at_risk: false)
    assert r.effective_at_risk?(NOW)
  end

  test "effective_at_risk? remains false before at_risk_at" do
    r = result(primary_state: 'met', breach_at: NOW + 1.hour,
               at_risk_at: NOW + 1.second, at_risk: false)
    refute r.effective_at_risk?(NOW)
  end

  test "effective_at_risk? is false once a would-be-at-risk row's breach_at has passed (live-reclassified to breached)" do
    r = result(primary_state: 'met', breach_at: NOW - 1.minute, at_risk: true)
    refute r.effective_at_risk?(NOW)
    assert_equal 'breached', r.effective_primary_state(NOW)
  end

  test "effective_at_risk? is false for a breached row even if the stale at_risk flag is still true" do
    r = result(primary_state: 'breached', at_risk: true)
    refute r.effective_at_risk?(NOW)
  end

  test "live-reclassified breach deviation advances from breach_at" do
    r = result(primary_state: 'met', breach_at: NOW - 20.minutes)
    assert_equal 20.minutes, r.effective_deviation_seconds(NOW)
  end

  test "persisted breach deviation advances from deviation_at" do
    r = result(primary_state: 'breached', deviation_seconds: 10.minutes,
               deviation_at: NOW - 25.minutes)
    assert_equal 25.minutes, r.effective_deviation_seconds(NOW)
  end

  test "historical deviation remains the floor when the current overage is smaller" do
    r = result(primary_state: 'breached', deviation_seconds: 2.hours,
               deviation_at: NOW - 25.minutes)
    assert_equal 2.hours, r.effective_deviation_seconds(NOW)
  end

  test "non-breached result has no effective deviation" do
    r = result(primary_state: 'met', breach_at: NOW + 1.hour, deviation_seconds: 10.minutes)
    assert_nil r.effective_deviation_seconds(NOW)
  end
end
