# frozen_string_literal: true

require 'rufus-scheduler'

module RedmineSlaCompliance
  # In-process scheduler for the at-risk / stale sweep.
  # Mirrors the established pattern in this install (redmine_time_analytics' schedulers): a
  # class-level rufus-scheduler singleton started once from `after_initialize`, guarded so it never
  # double-starts and never spins up under rake/migrations/tests. The actual work lives in
  # `Sla::Sweep`, which is unit-tested independently; this class only owns scheduling + isolation.
  #
  # The default cadence is every 15 minutes (the plan's default); the acceptance guarantee is that
  # a ticket crossing its at-risk window flips within ONE interval.
  class SweepScheduler
    SWEEP_CRON = '*/15 * * * *'

    @mutex     = Mutex.new
    @scheduler = nil
    @job       = nil

    class << self
      def start
        return if scheduler_disabled?

        @mutex.synchronize do
          return if @scheduler

          @scheduler = Rufus::Scheduler.new
          @job = @scheduler.cron(SWEEP_CRON) { run_sweep! }
        end
      end

      # Exposed for tests / graceful shutdown.
      def running?
        !@scheduler.nil?
      end

      private

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
