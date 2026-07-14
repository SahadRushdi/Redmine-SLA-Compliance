# frozen_string_literal: true

require_relative '../test_helper'

# RedmineSlaCompliance::NotificationLogDeduplicator — migration 002's guard against the exact
# landmine a real (non-empty) database hits: duplicate rows already written by the pre-fix
# check-then-act race must be collapsed to one per (issue_id, notification_type, target) BEFORE
# the unique index can be created, or `add_index unique: true` aborts outright.
#
# The unique index already exists in this fully-migrated test schema, so each test temporarily
# drops it to simulate the pre-migration state, seeds real duplicate rows via raw SQL (bypassing
# ActiveRecord validations entirely, exactly as the old race would have), runs the deduplicator,
# and then proves the index can be added back without error — the actual regression being guarded
# against.
#
# MySQL's DDL (DROP/ADD INDEX) implicitly commits and is NOT rolled back by a transaction, so this
# class can't rely on Rails' normal transactional test rollback for isolation — it manages its own
# cleanup in setup/teardown instead, defensively (idempotent, based on current DB state) so one
# failing test can't cascade into leaving the schema broken for every test that runs after it.
class NotificationLogDeduplicatorTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  INDEX_NAME = 'idx_sla_notification_logs_dedup_uniq'
  INDEX_COLUMNS = %i[issue_id notification_type target cycle_key].freeze

  setup do
    @connection = ActiveRecord::Base.connection
    SlaNotificationLog.delete_all
    drop_unique_index_if_present
  end

  teardown do
    SlaNotificationLog.delete_all
    restore_unique_index_if_missing
  end

  def drop_unique_index_if_present
    return unless @connection.index_exists?(:sla_notification_logs, INDEX_COLUMNS, name: INDEX_NAME)

    @connection.remove_index(:sla_notification_logs, name: INDEX_NAME)
  end

  def restore_unique_index_if_missing
    return if @connection.index_exists?(:sla_notification_logs, INDEX_COLUMNS, name: INDEX_NAME)

    @connection.add_index(:sla_notification_logs, INDEX_COLUMNS, unique: true, name: INDEX_NAME)
  end

  # `created_at`/`sent_at` are real Time objects, formatted for the raw SQL literal using
  # whichever timezone convention ActiveRecord itself will assume on read-back
  # (`ActiveRecord::Base.default_timezone` — this instance runs `:local`, i.e. the DB
  # server's OS timezone, not UTC) — otherwise the round-tripped value would silently land on a
  # different absolute instant than the test intends.
  def insert_raw(issue_id:, type: 'at_risk', target: '', sent_at: nil, created_at:)
    @connection.execute(
      "INSERT INTO sla_notification_logs " \
      "(issue_id, notification_type, target, cycle_key, sent_at, created_at, updated_at) " \
      "VALUES (#{issue_id}, #{@connection.quote(type)}, #{@connection.quote(target)}, '', " \
      "#{sent_at ? @connection.quote(sql_time(sent_at)) : 'NULL'}, #{@connection.quote(sql_time(created_at))}, " \
      "#{@connection.quote(sql_time(created_at))})"
    )
  end

  def sql_time(time)
    if ActiveRecord::Base.default_timezone == :utc
      time.getutc.strftime('%Y-%m-%d %H:%M:%S')
    else
      time.localtime.strftime('%Y-%m-%d %H:%M:%S')
    end
  end

  test "collapses duplicate rows to one per key, keeping the earliest" do
    t0 = Time.utc(2026, 1, 1, 9, 0, 0)
    insert_raw(issue_id: 1, created_at: t0, sent_at: t0) # earliest: sent immediately
    insert_raw(issue_id: 1, created_at: t0 + 1.minute, sent_at: nil) # a later duplicate
    insert_raw(issue_id: 1, created_at: t0 + 2.minutes, sent_at: t0 + 10.minutes)

    assert_equal 3, SlaNotificationLog.where(issue_id: 1, notification_type: 'at_risk').count

    RedmineSlaCompliance::NotificationLogDeduplicator.run!

    remaining = SlaNotificationLog.where(issue_id: 1, notification_type: 'at_risk')
    assert_equal 1, remaining.count
    assert_equal t0, remaining.first.sent_at
  end

  test "different issues, types, or targets are left alone" do
    t0 = Time.utc(2026, 1, 1, 9, 0, 0)
    insert_raw(issue_id: 1, type: 'at_risk', created_at: t0)
    insert_raw(issue_id: 2, type: 'at_risk', created_at: t0)
    insert_raw(issue_id: 1, type: 'stale', created_at: t0)

    RedmineSlaCompliance::NotificationLogDeduplicator.run!

    assert_equal 3, SlaNotificationLog.count
  end

  test "falls back to created_at ordering when sent_at is null on every duplicate" do
    t0 = Time.utc(2026, 1, 1, 9, 0, 0)
    insert_raw(issue_id: 1, created_at: t0 + 3.minutes, sent_at: nil)
    insert_raw(issue_id: 1, created_at: t0, sent_at: nil) # earliest queued
    insert_raw(issue_id: 1, created_at: t0 + 1.minute, sent_at: nil)

    RedmineSlaCompliance::NotificationLogDeduplicator.run!

    remaining = SlaNotificationLog.where(issue_id: 1)
    assert_equal 1, remaining.count
    assert_equal t0, remaining.first.created_at
  end

  test "the unique index can be created after deduping without error - the actual regression" do
    t0 = Time.utc(2026, 1, 1, 9, 0, 0)
    insert_raw(issue_id: 1, created_at: t0)
    insert_raw(issue_id: 1, created_at: t0 + 1.minute)
    insert_raw(issue_id: 1, created_at: t0 + 2.minutes)

    RedmineSlaCompliance::NotificationLogDeduplicator.run!

    assert_nothing_raised do
      @connection.add_index(:sla_notification_logs, INDEX_COLUMNS, unique: true, name: INDEX_NAME)
    end
  end

  test "is a no-op when there are no duplicates" do
    t0 = Time.utc(2026, 1, 1, 9, 0, 0)
    insert_raw(issue_id: 1, type: 'at_risk', created_at: t0)
    insert_raw(issue_id: 2, type: 'stale', created_at: t0)

    assert_no_difference -> { SlaNotificationLog.count } do
      RedmineSlaCompliance::NotificationLogDeduplicator.run!
    end
  end
end
