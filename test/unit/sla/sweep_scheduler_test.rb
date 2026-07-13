# frozen_string_literal: true

require_relative '../../test_helper'

# Sweep scheduler guards.
# The scheduler itself is a thin rufus wrapper; the sweep logic is covered by sweep_test.rb. Here we
# only assert the isolation guards: it never starts under rake/tests, honours an env kill-switch,
# and is idempotent (no second scheduler on a repeat start). We stub Rufus so no real background
# thread is spawned.
class Sla::SweepSchedulerTest < ActiveSupport::TestCase
  Scheduler = RedmineSlaCompliance::SweepScheduler

  teardown do
    # Never leave a (stubbed) scheduler set for other tests / the real boot.
    Scheduler.instance_variable_set(:@scheduler, nil)
    Scheduler.instance_variable_set(:@job, nil)
    ENV.delete('SLA_SWEEP_SCHEDULER_DISABLED')
  end

  test "sweeps on the plan's 15-minute cadence" do
    assert_equal '*/15 * * * *', Scheduler::SWEEP_CRON
  end

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

  test "start is idempotent - it creates only one scheduler" do
    fake = mock('rufus-scheduler')
    fake.stubs(:cron)
    Rufus::Scheduler.expects(:new).once.returns(fake)
    Scheduler.stubs(:scheduler_disabled?).returns(false)

    Scheduler.start
    Scheduler.start

    assert Scheduler.running?
  end
end
