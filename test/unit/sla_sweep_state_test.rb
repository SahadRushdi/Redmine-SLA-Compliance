# frozen_string_literal: true

require_relative '../test_helper'

# SlaSweepState — the atomic multi-process claim that lets only one app-server worker actually
# perform the sweep per interval (Phase 3 hardening, A4). Mirrors
# SlaNotificationSetting.claim_stale_digest_window!'s conditional-UPDATE pattern.
class SlaSweepStateTest < ActiveSupport::TestCase
  teardown { SlaSweepState.delete_all }

  test "claim_run! succeeds when no run has ever been claimed" do
    assert SlaSweepState.claim_run!(now: Time.current, interval_minutes: 15)
  end

  test "claim_run! creates the singleton row on first use" do
    SlaSweepState.claim_run!(now: Time.current, interval_minutes: 15)
    assert_equal 1, SlaSweepState.count
    assert_equal SlaSweepState::SINGLETON_ID, SlaSweepState.first.id
  end

  test "a second claim within the same interval fails - simulating a racing worker" do
    now = Time.current
    assert SlaSweepState.claim_run!(now: now, interval_minutes: 15)
    refute SlaSweepState.claim_run!(now: now, interval_minutes: 15)
    refute SlaSweepState.claim_run!(now: now + 5.minutes, interval_minutes: 15)
  end

  test "a claim succeeds again once the interval has elapsed" do
    now = Time.current
    assert SlaSweepState.claim_run!(now: now, interval_minutes: 15)
    assert SlaSweepState.claim_run!(now: now + 15.minutes, interval_minutes: 15)
  end

  test "a shortened interval lets the next claim succeed sooner, no rescheduling needed" do
    now = Time.current
    SlaSweepState.claim_run!(now: now, interval_minutes: 15)

    refute SlaSweepState.claim_run!(now: now + 5.minutes, interval_minutes: 15)
    assert SlaSweepState.claim_run!(now: now + 5.minutes, interval_minutes: 5),
           'a shorter configured interval is honoured on the very next check'
  end

  test "ensure_row! is idempotent and safe to call concurrently" do
    SlaSweepState.ensure_row!
    SlaSweepState.ensure_row!
    assert_equal 1, SlaSweepState.count
  end
end
