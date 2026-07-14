# frozen_string_literal: true

require_relative '../../test_helper'

# Sweep scheduler guards + the configurable-interval "tick" design (Phase 3 hardening).
# The scheduler itself is a thin rufus wrapper; the sweep logic is covered by sweep_test.rb. Here
# we assert: it never starts under rake/tests, honours an env kill-switch, is idempotent (no
# second scheduler on a repeat start), ticks on a fixed fine-grained cadence with overlap
# disabled, and only actually sweeps once the ADMIN-CONFIGURED interval has elapsed — so changing
# the setting takes effect on the next tick without any app restart or job rescheduling.
class Sla::SweepSchedulerTest < ActiveSupport::TestCase
  Scheduler = RedmineSlaCompliance::SweepScheduler

  setup do
    Setting.plugin_redmine_sla_compliance = {}
  end

  teardown do
    # Never leave a (stubbed) scheduler set for other tests / the real boot.
    Scheduler.instance_variable_set(:@scheduler, nil)
    Scheduler.instance_variable_set(:@job, nil)
    Scheduler.instance_variable_set(:@last_run_at, nil)
    ENV.delete('SLA_SWEEP_SCHEDULER_DISABLED')
    Setting.plugin_redmine_sla_compliance = {}
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

  # --- tick-based scheduling: the configurable interval, not the fixed Rufus job, gates runs --

  test "due? is true on the very first tick (no prior run recorded)" do
    assert Scheduler.send(:due?, Time.current)
  end

  test "due? is false until the configured interval has elapsed since the last run" do
    Setting.plugin_redmine_sla_compliance = { 'sweep_interval_minutes' => '15' }
    last = Time.current
    Scheduler.instance_variable_set(:@last_run_at, last)

    refute Scheduler.send(:due?, last + 14.minutes)
    assert Scheduler.send(:due?, last + 15.minutes)
  end

  test "shortening the configured interval makes a pending tick due sooner, with no rescheduling" do
    last = 10.minutes.ago
    Scheduler.instance_variable_set(:@last_run_at, last)

    Setting.plugin_redmine_sla_compliance = { 'sweep_interval_minutes' => '15' }
    refute Scheduler.send(:due?, Time.current), 'not yet due under the original 15-minute interval'

    Setting.plugin_redmine_sla_compliance = { 'sweep_interval_minutes' => '5' }
    assert Scheduler.send(:due?, Time.current),
           'the very next tick honours the shortened interval immediately'
  end

  test "tick! runs the sweep and records the run time when due" do
    Scheduler.instance_variable_set(:@last_run_at, nil)
    Scheduler.expects(:run_sweep!).once

    Scheduler.send(:tick!)

    refute_nil Scheduler.instance_variable_get(:@last_run_at)
  end

  test "tick! does not run the sweep when not yet due" do
    Setting.plugin_redmine_sla_compliance = { 'sweep_interval_minutes' => '15' }
    Scheduler.instance_variable_set(:@last_run_at, Time.current)
    Scheduler.expects(:run_sweep!).never

    Scheduler.send(:tick!)
  end
end
