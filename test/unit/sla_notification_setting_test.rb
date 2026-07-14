# frozen_string_literal: true

require_relative '../test_helper'

# SlaNotificationSetting — including `claim_stale_digest_window!` (Phase 3 hardening), the atomic
# schedule gate for the stale-ticket digest, mirroring SlaNotificationLog.claim!'s use of a real
# DB-level guard (a conditional UPDATE here) instead of an app-level check-then-act.
class SlaNotificationSettingTest < ActiveSupport::TestCase
  fixtures :projects

  PROJECT_ID = 1

  def make_setting(enabled: true, frequency: 'weekly', last_at: nil)
    SlaNotificationSetting.create!(project_id: PROJECT_ID, stale_email_enabled: enabled,
                                   stale_email_frequency: frequency, last_stale_digest_at: last_at)
  end

  test "stale_threshold_days must be a positive integer" do
    setting = SlaNotificationSetting.new(project_id: PROJECT_ID, stale_threshold_days: 0)
    refute setting.valid?
    assert_includes setting.errors[:stale_threshold_days], 'must be greater than 0'
  end

  test "stale_threshold_days defaults to 7" do
    assert_equal 7, SlaNotificationSetting.new(project_id: PROJECT_ID).stale_threshold_days
  end

  test "claim_stale_digest_window! returns nil when stale email is disabled" do
    make_setting(enabled: false)
    assert_nil SlaNotificationSetting.claim_stale_digest_window!(PROJECT_ID, now: Time.current)
  end

  test "claim_stale_digest_window! returns nil when no setting exists for the project" do
    assert_nil SlaNotificationSetting.claim_stale_digest_window!(999, now: Time.current)
  end

  test "claim_stale_digest_window! claims and stamps last_stale_digest_at when never run before" do
    setting = make_setting(last_at: nil)
    now = Time.current

    claimed = SlaNotificationSetting.claim_stale_digest_window!(PROJECT_ID, now: now)

    assert_equal setting, claimed
    assert_in_delta now, setting.reload.last_stale_digest_at, 1
  end

  test "claim_stale_digest_window! is a no-op before the configured frequency interval elapses" do
    make_setting(frequency: 'weekly', last_at: 3.days.ago)
    refute SlaNotificationSetting.claim_stale_digest_window!(PROJECT_ID, now: Time.current)
  end

  test "claim_stale_digest_window! claims again once the frequency interval has elapsed" do
    make_setting(frequency: 'weekly', last_at: 8.days.ago)
    assert SlaNotificationSetting.claim_stale_digest_window!(PROJECT_ID, now: Time.current)
  end

  test "claim_stale_digest_window! is atomic - a second concurrent claim in the same window fails" do
    make_setting(last_at: nil)
    now = Time.current

    first = SlaNotificationSetting.claim_stale_digest_window!(PROJECT_ID, now: now)
    second = SlaNotificationSetting.claim_stale_digest_window!(PROJECT_ID, now: now)

    assert first
    assert_nil second, 'a second caller racing the same window must not also claim it'
  end

  test "daily/monthly frequencies use their own interval" do
    make_setting(frequency: 'daily', last_at: 25.hours.ago)
    assert SlaNotificationSetting.claim_stale_digest_window!(PROJECT_ID, now: Time.current)

    SlaNotificationSetting.find_by(project_id: PROJECT_ID)
                          .update!(stale_email_frequency: 'monthly', last_stale_digest_at: 2.weeks.ago)
    refute SlaNotificationSetting.claim_stale_digest_window!(PROJECT_ID, now: Time.current)
  end
end
