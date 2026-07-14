# frozen_string_literal: true

require 'rufus-scheduler'

module RedmineSlaCompliance
  # In-process scheduler for the at-risk / stale sweep.
  # A class-level rufus-scheduler singleton started once from `after_initialize`, guarded so it
  # never double-starts and never spins up under rake/migrations/tests. The actual work lives in
  # `Sla::Sweep`, which is unit-tested independently; this class only owns scheduling + isolation.
  #
  # The cadence is admin-configurable (Administration → Plugins → SLA Compliance), defaulting to
  # 15 minutes per the plan's Fixed Decisions. Rather than scheduling a Rufus cron/interval job at
  # a fixed cadence and having to unschedule + reschedule it (racy to do safely from inside the
  # job's own callback) whenever the admin changes the setting, this runs a fine-grained internal
  # "tick" and only actually sweeps once the CONFIGURED interval has elapsed since the last sweep.
  # That makes a changed interval take effect on the very next tick, with no app restart and no
  # dynamic rescheduling of the underlying Rufus job.
  #
  # Whether-to-actually-sweep is decided by `SlaSweepState.claim_run!` — a DB-level atomic claim,
  # NOT process-local state. A production deployment normally runs several app-server worker
  # processes (Puma cluster mode, Passenger, Unicorn), each booting its own copy of this scheduler;
  # without a DB-level claim every worker would independently run the full sweep every interval
  # (N x the recompute load for no correctness benefit — Global Rule 4 is "do not break or slow
  # Redmine"). The claim means only one worker's tick actually performs the sweep per interval.
  #
  # Whether running the scheduler inside web-server workers is the right long-term answer for this
  # instance is still an open question (see Step 0.1's "confirm the scheduling mechanism" and the
  # note in the implementation plan) — an OS-level cron job invoking a rake task, or a
  # delayed_job/ActiveJob-scheduled recurring job, would avoid running scheduling logic inside
  # request-serving processes entirely and wouldn't need the claim above (a single cron invocation
  # has no sibling workers to race against). The atomic claim here makes the current in-process
  # approach *correct* under multiple workers; it doesn't settle whether it's the *right*
  # architecture for this Redmine instance long-term — that's a deployment decision, not a code fix.
  class SweepScheduler
    TICK_INTERVAL_SECONDS = 60

    @mutex     = Mutex.new
    @scheduler = nil
    @job       = nil

    class << self
      def start
        return if scheduler_disabled?

        @mutex.synchronize do
          return if @scheduler

          @scheduler = Rufus::Scheduler.new
          # overlap: false — if a sweep somehow overruns the tick, skip re-entering it rather than
          # stacking concurrent runs in the same process.
          @job = @scheduler.interval("#{TICK_INTERVAL_SECONDS}s", overlap: false) { tick! }
        end
      end

      # Exposed for tests / graceful shutdown.
      def running?
        !@scheduler.nil?
      end

      # The live-configured cadence in minutes — delegates to `Sla::PluginSettings` so the admin
      # settings screen and the scheduler read the exact same value.
      def interval_minutes
        Sla::PluginSettings.sweep_interval_minutes
      end

      private

      # Runs on every tick (every TICK_INTERVAL_SECONDS, in every worker process); only actually
      # sweeps if this call wins the DB-level claim for the current interval.
      def tick!
        return unless SlaSweepState.claim_run!(now: Time.current, interval_minutes: interval_minutes)

        run_sweep!
      end

      def run_sweep!
        # The scheduler runs on its own thread, so check out a dedicated connection; a failure is
        # logged and swallowed so one bad sweep never kills the recurring job.
        ActiveRecord::Base.connection_pool.with_connection do
          Sla::Sweep.new.run
        end
      rescue StandardError => e
        Rails.logger.error("[SLA::SweepScheduler] sweep failed: #{e.message}")
      end

      # Skip the background thread under rake tasks (incl. migrations and the manual sweep task) and
      # when explicitly disabled — so tests and one-off commands don't launch a scheduler.
      def scheduler_disabled?
        ENV['SLA_SWEEP_SCHEDULER_DISABLED'].to_s == '1' ||
          File.basename($PROGRAM_NAME) == 'rake'
      end
    end
  end
end
