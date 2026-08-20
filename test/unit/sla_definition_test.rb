# frozen_string_literal: true

require_relative '../test_helper'

# SlaDefinition — numeric wall-clock targets and Best Effort targets.
class SlaDefinitionTest < ActiveSupport::TestCase
  fixtures :projects

  setup do
    @project = Project.find(1)
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

  test "a direct wall-clock target validates without a catalog row" do
    d = SlaDefinition.new(tracker_id: 1, priority_id: 4, response_seconds: 3600)
    assert_nothing_raised { d.valid? }
  end
end
