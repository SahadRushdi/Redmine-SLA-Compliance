# frozen_string_literal: true

require_relative '../../test_helper'

# Sweep scheduler guards + the configurable-interval "tick" design (Phase 3 hardening).
# The scheduler itself is a thin rufus wrapper; the sweep logic is covered by sweep_test.rb, and
# the atomic multi-process claim is covered by sla_sweep_state_test.rb. Here we assert: it never
# starts under rake/tests, honours an env kill-switch, is idempotent (no second scheduler on a
# repeat start), ticks on a fixed fine-grained cadence with overlap disabled, and that `tick!`
# defers entirely to `SlaSweepState.claim_run!` to decide whether to actually sweep.
class Sla::SweepSchedulerTest < ActiveSupport::TestCase
  Scheduler = RedmineSlaCompliance::SweepScheduler

  setup do
    Setting.plugin_redmine_sla_compliance = {}
    SlaSweepState.delete_all
  end

  teardown do
    # Never leave a (stubbed) scheduler set for other tests / the real boot.
    Scheduler.instance_variable_set(:@scheduler, nil)
    Scheduler.instance_variable_set(:@job, nil)
    ENV.delete('SLA_SWEEP_SCHEDULER_DISABLED')
    Setting.plugin_redmine_sla_compliance = {}
    SlaSweepState.delete_all
  end

  # --- admin-configurable interval (delegates to Sla::PluginSettings) -----------------------

  test "interval_minutes defaults to 15 when unset" do
    assert_equal 15, Scheduler.interval_minutes
  end

  test "interval_minutes reads the admin-configured value from plugin settings" do
    Setting.plugin_redmine_sla_compliance = { 'sweep_interval_minutes' => '30' }
    assert_equal 30, Scheduler.interval_minutes
  end

  # --- isolation guards -----------------------------------------------------------------------

  test "the scheduler is disabled under rake (so tests and migrations never start it)" do
    # The plugin test suite runs via `rake redmine:plugins:test`, so the rake guard is active here.
    assert Scheduler.send(:scheduler_disabled?)
  end

  test "an explicit env kill-switch disables the scheduler" do
    ENV['SLA_SWEEP_SCHEDULER_DISABLED'] = '1'
    assert Scheduler.send(:scheduler_disabled?)
  end

  test "start is a no-op while disabled" do
    Scheduler.start # disabled under rake
    refute Scheduler.running?
  end

  test "start is idempotent - it creates only one scheduler, ticking every 60s without overlap" do
    fake = mock('rufus-scheduler')
    fake.expects(:interval).with('60s', overlap: false)
    Rufus::Scheduler.expects(:new).once.returns(fake)
    Scheduler.stubs(:scheduler_disabled?).returns(false)

    Scheduler.start
    Scheduler.start

    assert Scheduler.running?
  end

  # --- tick! defers to the atomic DB claim, not process-local state --------------------------

  test "tick! runs the sweep when it wins the DB claim" do
    Scheduler.expects(:run_sweep!).once

    Scheduler.send(:tick!)
  end

  test "tick! does not run the sweep when the claim is already held for this interval" do
    Setting.plugin_redmine_sla_compliance = { 'sweep_interval_minutes' => '15' }
    SlaSweepState.claim_run!(now: Time.current, interval_minutes: 15) # another worker just won it
    Scheduler.expects(:run_sweep!).never

    Scheduler.send(:tick!)
  end

  test "a second worker's tick in the same interval never also sweeps" do
    Scheduler.expects(:run_sweep!).once # only the first tick's claim should succeed

    Scheduler.send(:tick!) # simulates worker A
    Scheduler.send(:tick!) # simulates worker B racing the same interval
  end
end
