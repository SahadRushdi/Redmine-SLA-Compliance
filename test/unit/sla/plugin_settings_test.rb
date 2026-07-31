# frozen_string_literal: true

require_relative '../../test_helper'

# Global, admin-configurable plugin settings (Administration → Plugins → SLA Compliance),
# backed by Redmine's own plugin-settings hash — no plugin table for these two values.
class Sla::PluginSettingsTest < ActiveSupport::TestCase
  fixtures :enumerations, :users, :email_addresses

  setup do
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  # --- sweep_interval_minutes -----------------------------------------------------------------

  test "sweep_interval_minutes defaults to 15 when unset" do
    assert_equal 15, Sla::PluginSettings.sweep_interval_minutes
  end

  test "sweep_interval_minutes reads a configured positive value" do
    Setting.plugin_redmine_sla_compliance = { 'sweep_interval_minutes' => '5' }
    assert_equal 5, Sla::PluginSettings.sweep_interval_minutes
  end

  test "sweep_interval_minutes falls back to the default for a blank/zero/negative value" do
    ['', '0', '-5', nil].each do |bad|
      Setting.plugin_redmine_sla_compliance = { 'sweep_interval_minutes' => bad }
      assert_equal 15, Sla::PluginSettings.sweep_interval_minutes, "for #{bad.inspect}"
    end
  end

  test "sweep_interval_minutes clamps an absurdly large value to the max" do
    Setting.plugin_redmine_sla_compliance = { 'sweep_interval_minutes' => '999999' }
    assert_equal 1440, Sla::PluginSettings.sweep_interval_minutes
  end

  # --- unclassified_priority_id ---------------------------------------------------------------

  test "unclassified_priority_id auto-detects a priority literally named 'None' (case-insensitive)" do
    none = IssuePriority.create!(name: 'NoNe', type: 'IssuePriority', position: 99)
    assert_equal none.id, Sla::PluginSettings.unclassified_priority_id
  end

  test "unclassified_priority_id is nil when nothing is configured and no priority is named 'None'" do
    assert_nil Sla::PluginSettings.unclassified_priority_id
  end

  test "an explicitly configured id wins over auto-detection" do
    none = IssuePriority.create!(name: 'None', type: 'IssuePriority', position: 99)
    other = IssuePriority.find(4) # Low, from fixtures
    Setting.plugin_redmine_sla_compliance = { 'unclassified_priority_id' => other.id.to_s }

    assert_equal other.id, Sla::PluginSettings.unclassified_priority_id
    assert_not_equal none.id, Sla::PluginSettings.unclassified_priority_id
  end

  # --- the Step 5.1 access allow-lists ---------------------------------------------------------
  #
  # The settings form posts strings and a blank sentinel entry, and Redmine's settings controller
  # stores what it is given verbatim (`permit!.to_h`) — so every bit of cleanup has to happen on
  # read, here.

  test "both user id lists default to empty when nothing is configured" do
    assert_equal [], Sla::PluginSettings.viewer_user_ids
    assert_equal [], Sla::PluginSettings.manager_user_ids
  end

  test "user ids are parsed from the posted strings into integers" do
    Setting.plugin_redmine_sla_compliance = {
      'sla_viewer_user_ids' => %w[4 7],
      'sla_manager_user_ids' => %w[2]
    }

    assert_equal [4, 7], Sla::PluginSettings.viewer_user_ids
    assert_equal [2], Sla::PluginSettings.manager_user_ids
  end

  test "the blank sentinel the form always posts is dropped" do
    # The picker posts a leading '' so the [] param still arrives when every chip is removed;
    # without this, the allow-list would contain a user id of 0.
    Setting.plugin_redmine_sla_compliance = { 'sla_viewer_user_ids' => ['', '4'] }

    assert_equal [4], Sla::PluginSettings.viewer_user_ids
  end

  test "clearing every chip persists as an empty list, not a list containing 0" do
    Setting.plugin_redmine_sla_compliance = { 'sla_viewer_user_ids' => [''] }

    assert_equal [], Sla::PluginSettings.viewer_user_ids
  end

  test "duplicate ids collapse" do
    Setting.plugin_redmine_sla_compliance = { 'sla_manager_user_ids' => %w[2 2 3] }

    assert_equal [2, 3], Sla::PluginSettings.manager_user_ids
  end

  test "a nil or non-array value is tolerated rather than raising" do
    # What a hand-edited, or pre-5.1, settings hash looks like.
    [nil, '', '4'].each do |value|
      Setting.plugin_redmine_sla_compliance = { 'sla_viewer_user_ids' => value }
      assert_nothing_raised { Sla::PluginSettings.viewer_user_ids }
    end
  end

  test "the two lists are independent" do
    Setting.plugin_redmine_sla_compliance = { 'sla_manager_user_ids' => %w[2] }

    assert_equal [], Sla::PluginSettings.viewer_user_ids
    assert_equal [2], Sla::PluginSettings.manager_user_ids
  end

  # --- the User records behind the ids (used to render the preselected chips) -------------------

  test "viewer_users / manager_users resolve the ids to User records" do
    Setting.plugin_redmine_sla_compliance = {
      'sla_viewer_user_ids' => %w[4],
      'sla_manager_user_ids' => %w[2 3]
    }

    assert_equal [4], Sla::PluginSettings.viewer_users.map(&:id)
    assert_equal [2, 3], Sla::PluginSettings.manager_users.map(&:id).sort
  end

  test "an id whose user has since been deleted is silently skipped" do
    Setting.plugin_redmine_sla_compliance = { 'sla_viewer_user_ids' => %w[4 999999] }

    assert_equal [4], Sla::PluginSettings.viewer_users.map(&:id),
                 'a stale id must not blow up the settings form'
  end

  test "viewer_users is empty without a query when nothing is listed" do
    assert_equal [], Sla::PluginSettings.viewer_users.to_a
  end


  # --- Step 7.1: global Google Chat webhook ---------------------------------------------------

  test "default_google_chat_webhook is nil when unset or blank" do
    assert_nil Sla::PluginSettings.default_google_chat_webhook

    Setting.plugin_redmine_sla_compliance = { 'google_chat_webhook' => '' }
    assert_nil Sla::PluginSettings.default_google_chat_webhook,
               'a blank field must read as "no global fallback", not as an empty URL'
  end

  test "default_google_chat_webhook reads the configured value" do
    url = 'https://chat.googleapis.com/v1/spaces/AAA/messages?key=k'
    Setting.plugin_redmine_sla_compliance = { 'google_chat_webhook' => url }
    assert_equal url, Sla::PluginSettings.default_google_chat_webhook
  end
end
