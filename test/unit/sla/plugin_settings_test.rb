# frozen_string_literal: true

require_relative '../../test_helper'

# Global, admin-configurable plugin settings (Administration → SLA Compliance),
# backed by Redmine's own plugin-settings hash — no plugin table for these values.
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

  # --- the Step 5.1 SLA access roles -----------------------------------------------------------
  #
  # The settings form posts strings and a blank sentinel entry, and #update stores what it is
  # given verbatim — so every bit of cleanup has to happen on read, here.

  test "the role id list defaults to empty when nothing is configured" do
    assert_equal [], Sla::PluginSettings.access_role_ids
  end

  test "role ids are parsed from the posted strings into integers" do
    Setting.plugin_redmine_sla_compliance = { 'sla_access_role_ids' => %w[1 3] }

    assert_equal [1, 3], Sla::PluginSettings.access_role_ids
  end

  test "the blank sentinel the form always posts is dropped" do
    # The picker posts a leading '' so the [] param still arrives when every chip is removed;
    # without this, the list would contain a role id of 0.
    Setting.plugin_redmine_sla_compliance = { 'sla_access_role_ids' => ['', '3'] }

    assert_equal [3], Sla::PluginSettings.access_role_ids
  end

  test "clearing every chip persists as an empty list, not a list containing 0" do
    Setting.plugin_redmine_sla_compliance = { 'sla_access_role_ids' => [''] }

    assert_equal [], Sla::PluginSettings.access_role_ids
  end

  test "duplicate ids collapse" do
    Setting.plugin_redmine_sla_compliance = { 'sla_access_role_ids' => %w[2 2 3] }

    assert_equal [2, 3], Sla::PluginSettings.access_role_ids
  end

  test "a nil or non-array value is tolerated rather than raising" do
    # What a hand-edited, or pre-2026-08-06, settings hash looks like.
    [nil, '', '4'].each do |value|
      Setting.plugin_redmine_sla_compliance = { 'sla_access_role_ids' => value }
      assert_nothing_raised { Sla::PluginSettings.access_role_ids }
    end
  end

  test "the retired per-user allow-lists are not read as roles" do
    # They may still sit in a settings hash saved before 2026-08-06; nothing may resurrect them,
    # least of all as role ids, which would grant SLA access to whoever holds those role numbers.
    Setting.plugin_redmine_sla_compliance = {
      'sla_viewer_user_ids' => %w[4],
      'sla_manager_user_ids' => %w[2]
    }

    assert_equal [], Sla::PluginSettings.access_role_ids
  end


  # NOTE: Sla::PluginSettings.default_google_chat_webhook (Step 7.1's instance-wide fallback) was
  # removed on 2026-08-05 along with its admin field; its tests went with it. A webhook is now a
  # per-project setting only — see SlaNotificationSettingTest.
end
