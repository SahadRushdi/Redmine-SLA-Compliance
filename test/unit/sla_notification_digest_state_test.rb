# frozen_string_literal: true

require_relative '../test_helper'

class SlaNotificationDigestStateTest < ActiveSupport::TestCase
  fixtures :projects

  test 'claims a target project window atomically and reopens after the interval' do
    now = Time.zone.local(2026, 8, 11, 10, 0)

    first = SlaNotificationDigestState.claim_stale_window!(1, 1.week, now: now)
    second = SlaNotificationDigestState.claim_stale_window!(1, 1.week, now: now)
    later = SlaNotificationDigestState.claim_stale_window!(1, 1.week, now: now + 8.days)

    assert first
    assert_nil second
    assert later
    assert_in_delta now + 8.days, later.last_stale_digest_at, 1
  end

  test 'projects sharing one configuration retain independent windows' do
    now = Time.zone.local(2026, 8, 11, 10, 0)

    assert SlaNotificationDigestState.claim_stale_window!(3, 1.week, now: now)
    assert SlaNotificationDigestState.claim_stale_window!(4, 1.week, now: now)
  end

  test 'at-risk digest has an independent configurable interval' do
    now = Time.zone.local(2026, 8, 13, 10, 0)

    assert SlaNotificationDigestState.claim_at_risk_window!(1, 60.minutes, now: now)
    assert_nil SlaNotificationDigestState.claim_at_risk_window!(1, 60.minutes, now: now + 59.minutes)
    assert SlaNotificationDigestState.claim_at_risk_window!(1, 60.minutes, now: now + 60.minutes)
  end
end
