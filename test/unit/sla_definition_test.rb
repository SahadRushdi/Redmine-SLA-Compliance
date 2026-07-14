# frozen_string_literal: true

require_relative '../test_helper'

# SlaDefinition — including B4's any_target? extension (Best Effort counts) and the
# business-basis-requires-business-hours-coverage validation.
class SlaDefinitionTest < ActiveSupport::TestCase
  fixtures :projects

  setup do
    @project = Project.find(1)
  end

  def make_policy(coverage_hours: '24x7')
    attrs = { project_id: @project.id, enabled: true, coverage_hours: coverage_hours }
    if coverage_hours == 'business_hours'
      calendar = SlaBusinessCalendar.create!(name: 'Std', working_days: [1, 2, 3, 4, 5],
                                             work_start_time: '09:00', work_end_time: '17:00')
      attrs[:business_calendar_id] = calendar.id
    end
    SlaPolicy.create!(attrs)
  end

  # --- any_target? -----------------------------------------------------------------------

  test "any_target? is false with nothing set" do
    refute SlaDefinition.new.any_target?
  end

  test "any_target? is true with a numeric seconds value" do
    assert SlaDefinition.new(response_seconds: 3600).any_target?
  end

  test "any_target? is true with only a Best Effort flag, no numeric seconds" do
    assert SlaDefinition.new(resolution_best_effort: true).any_target?
  end

  test "best_effort?(type) reads the corresponding column" do
    d = SlaDefinition.new(resolution_best_effort: true)
    assert d.best_effort?(:resolution)
    refute d.best_effort?(:response)
  end

  # --- business-basis validation ----------------------------------------------------------

  test "a calendar-basis target is valid under 24x7 coverage" do
    policy = make_policy(coverage_hours: '24x7')
    SlaTargetOption.create!(target_type: 'resolution', code: '2d', label: '2 days', seconds: 172_800,
                            basis: 'calendar')
    d = SlaDefinition.new(sla_policy: policy, tracker_id: 1, priority_id: 4, resolution_seconds: 172_800)
    assert d.valid?
  end

  test "a business-basis target is rejected under 24x7 coverage" do
    policy = make_policy(coverage_hours: '24x7')
    SlaTargetOption.create!(target_type: 'resolution', code: '1bd', label: '1 Business Day',
                            seconds: 28_800, basis: 'business')
    d = SlaDefinition.new(sla_policy: policy, tracker_id: 1, priority_id: 4, resolution_seconds: 28_800)
    refute d.valid?
    assert d.errors[:base].present?
  end

  test "a business-basis target is valid under Business Hours coverage" do
    policy = make_policy(coverage_hours: 'business_hours')
    SlaTargetOption.create!(target_type: 'resolution', code: '1bd', label: '1 Business Day',
                            seconds: 28_800, basis: 'business')
    d = SlaDefinition.new(sla_policy: policy, tracker_id: 1, priority_id: 4, resolution_seconds: 28_800)
    assert d.valid?
  end

  test "a Best Effort target (no seconds) is never blocked by the basis check" do
    policy = make_policy(coverage_hours: '24x7')
    d = SlaDefinition.new(sla_policy: policy, tracker_id: 1, priority_id: 4, resolution_best_effort: true)
    assert d.valid?
  end

  test "with no policy association, the basis check is skipped rather than raising" do
    d = SlaDefinition.new(tracker_id: 1, priority_id: 4, response_seconds: 3600)
    assert_nothing_raised { d.valid? }
  end
end
