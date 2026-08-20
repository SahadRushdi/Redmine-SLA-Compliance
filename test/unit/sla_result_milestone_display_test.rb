# frozen_string_literal: true

require_relative '../test_helper'

class SlaResultMilestoneDisplayTest < ActiveSupport::TestCase
  test "pending engine clocks are not exposed as completed milestone durations" do
    result = SlaResult.new(response_seconds: 17.minutes, resolution_seconds: 31.minutes)

    assert_nil result.completed_response_seconds
    assert_nil result.completed_resolution_seconds
  end

  test "completed milestones expose their elapsed durations" do
    result = SlaResult.new(response_seconds: 17.minutes, resolution_seconds: 31.minutes,
                           first_response_at: 1.hour.ago, resolved_at: 30.minutes.ago)

    assert_equal 17.minutes, result.completed_response_seconds
    assert_equal 31.minutes, result.completed_resolution_seconds
  end
end
