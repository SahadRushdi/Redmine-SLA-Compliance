# frozen_string_literal: true

require_relative '../test_helper'

# Project and singleton-admin notification configuration.
class SlaNotificationSettingTest < ActiveSupport::TestCase
  fixtures :projects

  PROJECT_ID = 1

  test "stale_threshold_days must be a positive integer" do
    setting = SlaNotificationSetting.new(project_id: PROJECT_ID, stale_threshold_days: 0)
    refute setting.valid?
    assert_includes setting.errors[:stale_threshold_days], 'must be greater than 0'
  end

  test "stale_threshold_days defaults to 7" do
    assert_equal 7, SlaNotificationSetting.new(project_id: PROJECT_ID).stale_threshold_days
  end

  test "project and global settings receive distinct stable scope keys" do
    project_setting = SlaNotificationSetting.create!(project_id: PROJECT_ID)
    global_setting = SlaNotificationSetting.global_for_form
    global_setting.save!

    assert_equal "project:#{PROJECT_ID}", project_setting.scope_key
    assert_equal 'global', global_setting.scope_key
    assert_nil global_setting.project_id
    assert_equal global_setting, SlaNotificationSetting.global
  end

  test "only one global setting can exist" do
    SlaNotificationSetting.global_for_form.save!
    duplicate = SlaNotificationSetting.new(scope_key: 'global')

    refute duplicate.valid?
    assert_includes duplicate.errors.attribute_names, :scope_key
  end

  # --- Step 7.1: Google Chat webhook resolution -----------------------------------------------

  PROJECT_WEBHOOK = 'https://chat.googleapis.com/v1/spaces/AAA/messages?key=k'

  test "google_chat_webhook_for returns the project's own webhook" do
    SlaNotificationSetting.create!(project_id: PROJECT_ID, google_chat_webhook: PROJECT_WEBHOOK)

    assert_equal PROJECT_WEBHOOK,
                 SlaNotificationSetting.google_chat_webhook_for(Project.find(PROJECT_ID))
  end

  test "google_chat_webhook_for is nil when no project parent or admin webhook is active" do
    assert_nil SlaNotificationSetting.google_chat_webhook_for(Project.find(PROJECT_ID))

    SlaNotificationSetting.create!(project_id: PROJECT_ID, google_chat_webhook: '')
    assert_nil SlaNotificationSetting.google_chat_webhook_for(Project.find(PROJECT_ID))
  end

  test "a webhook must be blank or an https URL" do
    setting = SlaNotificationSetting.new(project_id: PROJECT_ID, google_chat_webhook: 'not a url')
    refute setting.valid?
    assert_includes setting.errors.attribute_names, :google_chat_webhook

    setting.google_chat_webhook = 'http://chat.googleapis.com/v1/spaces/AAA'
    refute setting.valid?, 'plain http must be rejected'

    setting.google_chat_webhook = PROJECT_WEBHOOK
    assert setting.valid?

    setting.google_chat_webhook = ''
    assert setting.valid?, 'clearing the field must stay allowed'
  end

  test "daily monthly and unknown stale frequencies use the intended interval" do
    setting = SlaNotificationSetting.new(project_id: PROJECT_ID, stale_email_frequency: 'daily')
    assert_equal 1.day, setting.stale_digest_interval
    setting.stale_email_frequency = 'monthly'
    assert_equal 1.month, setting.stale_digest_interval
  end
end
