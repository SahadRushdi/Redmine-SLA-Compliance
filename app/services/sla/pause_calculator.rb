# frozen_string_literal: true

module Sla
  # Phase 2 · Step 2.4 — Pause/exclusion handling.
  #
  # Subtracts time spent in configured pause statuses from a milestone's elapsed time
  # (Response / Workaround / Resolution, and each Update Frequency gap). Pause statuses are the
  # `pause`-role status IDs from the policy (SlaStatusMapping); the elapsed math is delegated to
  # whichever calculator the policy's coverage mode selects — Sla::CalendarTimeCalculator (24x7) or
  # Sla::BusinessHoursCalculator (business hours).
  #
  # Because paused time is measured with the SAME calculator as the milestone, the subtraction
  # is always consistent: in business-hours mode a pause spanning a weekend removes only its
  # working-hours portion (the weekend was never counted in the first place).
  #
  # Consumes the timeline's `status_intervals` (per-status spans, last span open-ended). Pure
  # and side-effect free: no DB, no writes.
  class PauseCalculator
    def initialize(timeline, pause_status_ids:, calculator:)
      @timeline         = timeline
      @pause_status_ids = Array(pause_status_ids)
      @calculator       = calculator
    end

    # Total paused time (seconds) within the window [from, to], measured in the calculator's mode.
    def paused_seconds(from, to)
      return 0 if from.nil? || to.nil? || to <= from || @pause_status_ids.empty?

      @timeline.status_intervals.sum do |interval|
        next 0 unless pause?(interval[:status_id])

        segment_start = [interval[:started_at], from].max
        segment_end   = [interval[:ended_at] || to, to].min
        segment_end > segment_start ? @calculator.elapsed(segment_start, segment_end) : 0
      end
    end

    # Milestone elapsed time in [from, to] with paused time removed (never negative).
    def net_elapsed(from, to)
      gross = @calculator.elapsed(from, to)
      [gross - paused_seconds(from, to), 0].max
    end

    private

    def pause?(status_id)
      @pause_status_ids.include?(status_id)
    end
  end
end
