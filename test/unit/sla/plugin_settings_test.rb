# frozen_string_literal: true

require_relative '../../test_helper'

# Global, admin-configurable plugin settings (Administration → Plugins → SLA Compliance),
# backed by Redmine's own plugin-settings hash — no plugin table for these two values.
class Sla::PluginSettingsTest < ActiveSupport::TestCase
  fixtures :enumerations

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
end
