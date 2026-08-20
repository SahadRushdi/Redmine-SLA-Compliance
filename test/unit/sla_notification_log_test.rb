# frozen_string_literal: true

require_relative '../test_helper'

# SlaNotificationLog — the dedup ledger. `claim!` (Phase 3 hardening) must be a real atomic guard:
# the first caller for a given (issue, type, target) wins, every subsequent caller loses, backed
# by the DB's unique index (migration 002) rather than an app-level check-then-act query.
class SlaNotificationLogTest < ActiveSupport::TestCase
  fixtures :issues

  ISSUE_ID = 1

  test "claim! succeeds the first time and returns true" do
    assert SlaNotificationLog.claim!(issue_id: ISSUE_ID, notification_type: 'at_risk')
    assert_equal 1, SlaNotificationLog.where(issue_id: ISSUE_ID, notification_type: 'at_risk').count
  end

  test "claim! fails every subsequent time for the same issue+type+target" do
    assert SlaNotificationLog.claim!(issue_id: ISSUE_ID, notification_type: 'at_risk')
    refute SlaNotificationLog.claim!(issue_id: ISSUE_ID, notification_type: 'at_risk')
    refute SlaNotificationLog.claim!(issue_id: ISSUE_ID, notification_type: 'at_risk')

    assert_equal 1, SlaNotificationLog.where(issue_id: ISSUE_ID, notification_type: 'at_risk').count,
                 'only one row must ever exist for this combination'
  end

  test "claim! is enforced by a real DB constraint, not just application logic" do
    # Bypass the application-level `claim!` guard entirely and hit the DB directly twice, exactly
    # as two racing processes would if the check-then-act pattern were still in place — the
    # second insert must fail at the database layer.
    SlaNotificationLog.create!(issue_id: ISSUE_ID, notification_type: 'at_risk', target: '')
    assert_raises(ActiveRecord::RecordNotUnique) do
      SlaNotificationLog.connection.execute(
        "INSERT INTO sla_notification_logs (issue_id, notification_type, target, created_at, updated_at) " \
        "VALUES (#{ISSUE_ID}, 'at_risk', '', NOW(), NOW())"
      )
    end
  end

  test "different targets for the same issue+type are independent claims" do
    assert SlaNotificationLog.claim!(issue_id: ISSUE_ID, notification_type: 'at_risk', target: 'response')
    assert SlaNotificationLog.claim!(issue_id: ISSUE_ID, notification_type: 'at_risk', target: 'resolution')
    refute SlaNotificationLog.claim!(issue_id: ISSUE_ID, notification_type: 'at_risk', target: 'response')
  end

  test "claim! defaults target to '' (not nil) so the unique index actually applies" do
    SlaNotificationLog.claim!(issue_id: ISSUE_ID, notification_type: 'stale')
    assert_equal '', SlaNotificationLog.last.target
  end

  test "already_sent? reflects claimed rows" do
    refute SlaNotificationLog.already_sent?(issue_id: ISSUE_ID, notification_type: 'at_risk')
    SlaNotificationLog.claim!(issue_id: ISSUE_ID, notification_type: 'at_risk')
    assert SlaNotificationLog.already_sent?(issue_id: ISSUE_ID, notification_type: 'at_risk')
  end

  test 'delivery lifecycle is atomically queued and records success or failure' do
    log = SlaNotificationLog.claim!(issue_id: ISSUE_ID, notification_type: 'at_risk',
                                    target: 'response', cycle_key: 'delivery')
    assert_equal 'pending', log.delivery_state
    assert log.queue!
    refute log.queue!
    log.sent!
    assert_equal 'sent', log.reload.delivery_state
    assert_not_nil log.sent_at
  end
end
