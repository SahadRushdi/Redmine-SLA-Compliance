# frozen_string_literal: true

require_relative '../../test_helper'

# Sla::PolicyContext — per-project configuration resolution.
class Sla::PolicyContextTest < ActiveSupport::TestCase
  fixtures :projects, :enumerations, :trackers

  TRACKER = 1
  PRIORITY = 6 # High, from fixtures

  setup do
    Setting.plugin_redmine_sla_compliance = {}
    @project = Project.find(1)
    @policy = SlaPolicy.create!(project_id: @project.id, enabled: true, coverage_hours: '24x7',
                                first_response_rule: 'either', at_risk_threshold: 80,
                                pause_enabled: true)
  end

  teardown do
    Setting.plugin_redmine_sla_compliance = {}
  end

  test "tracker_configured? is true only for trackers with at least one definition" do
    SlaDefinition.create!(sla_policy: @policy, tracker_id: TRACKER, priority_id: PRIORITY,
                          response_seconds: 3600)
    context = Sla::PolicyContext.new(@policy)

    assert context.tracker_configured?(TRACKER)
    refute context.tracker_configured?(999)
  end

  test "definition_for returns the matching SlaDefinition" do
    definition = SlaDefinition.create!(sla_policy: @policy, tracker_id: TRACKER,
                                       priority_id: PRIORITY, response_seconds: 3600)
    context = Sla::PolicyContext.new(@policy)

    assert_equal definition, context.definition_for(TRACKER, PRIORITY)
  end

  test "a removed tracker is inactive while its definitions remain available for restoration" do
    definition = SlaDefinition.create!(sla_policy: @policy, tracker_id: TRACKER,
                                       priority_id: PRIORITY, response_seconds: 3600)
    @policy.update!(selected_tracker_ids: [])
    context = Sla::PolicyContext.new(@policy)

    refute context.tracker_configured?(TRACKER)
    assert_nil context.definition_for(definition.tracker_id, definition.priority_id)
    assert definition.persisted?, 'removing a tracker keeps its target values for later restoration'
  end

  test "definition_for treats a priority named None like every other configured priority" do
    none = IssuePriority.create!(name: 'None', type: 'IssuePriority', position: 99)
    definition = SlaDefinition.create!(sla_policy: @policy, tracker_id: TRACKER, priority_id: none.id,
                                       response_seconds: 3600)

    context = Sla::PolicyContext.new(@policy)

    assert_equal definition, context.definition_for(TRACKER, none.id)
  end

  test "a nil policy yields an empty, not-configured context" do
    context = Sla::PolicyContext.new(nil)

    refute context.tracker_configured?(TRACKER)
    assert_nil context.definition_for(TRACKER, PRIORITY)
    assert_equal({}, context.status_roles)
  end
end
