require_relative '../test_helper'

class SlaRecalculationStateTest < ActiveSupport::TestCase
  fixtures :projects

  setup do
    SlaRecalculationState.delete_all
    @project = Project.find(1)
    @now = Time.current
  end

  test "the first request queues a run and a queued duplicate reuses it" do
    state, enqueue = SlaRecalculationState.request!(@project, now: @now)
    duplicate, duplicate_enqueue = SlaRecalculationState.request!(@project, now: @now + 1.minute)

    assert enqueue
    refute duplicate_enqueue
    assert_equal state.run_token, duplicate.run_token
    refute duplicate.rerun_requested?
  end

  test "a request during processing coalesces one follow-up pass" do
    state, = SlaRecalculationState.request!(@project, now: @now)
    assert state.start!(state.run_token, now: @now + 1.second)

    duplicate, enqueue = SlaRecalculationState.request!(@project, now: @now + 1.minute)

    refute enqueue
    assert duplicate.reload.rerun_requested?
    assert_equal :rerun, duplicate.finish_pass!(state.run_token, processed: 4, now: @now + 2.minutes)
    assert_equal :completed,
                 duplicate.finish_pass!(state.run_token, processed: 4, now: @now + 3.minutes)
    assert_equal 100, duplicate.reload.progress_percentage
  end

  test "a stale active run is replaced and rejects progress from its old token" do
    old_state, = SlaRecalculationState.request!(@project, now: @now)
    old_token = old_state.run_token
    old_state.update_columns(status: 'running', updated_at: @now - 2.hours)

    replacement, enqueue = SlaRecalculationState.request!(@project, now: @now)

    assert enqueue
    assert_not_equal old_token, replacement.run_token
    refute old_state.record_progress!(old_token, processed: 1, total: 2)
    assert_equal 0, replacement.reload.processed_count
  end

  test "progress is clamped and written only when its integer percentage advances" do
    state, = SlaRecalculationState.request!(@project, now: @now)
    state.start!(state.run_token, now: @now)

    assert state.record_progress!(state.run_token, processed: 1, total: 200)
    refute state.record_progress!(state.run_token, processed: 1, total: 200)
    assert state.record_progress!(state.run_token, processed: 2, total: 200)

    state.reload
    assert_equal 2, state.processed_count
    assert_equal 1, state.progress_percentage
  end
end
