# frozen_string_literal: true

module Sla
  # Phase 2 · Step 2.2 — Calendar-time elapsed calculation.
  #
  # Computes the elapsed wall-clock time, in whole seconds, between two events. This is the
  # real physical duration that passed between the two instants — what a 24x7 (`coverage_hours
  # = '24x7'`) SLA measures.
  #
  # Correctness across day / month / year / DST boundaries falls out for free: Ruby `Time` and
  # `ActiveSupport::TimeWithZone` are absolute instants, so the epoch-second difference already
  # accounts for months of different lengths, leap days, and daylight-saving transitions (a
  # 01:30→03:30 span across a spring-forward is one real hour, not two). No date arithmetic is
  # performed, which is exactly what keeps this immune to those boundary bugs.
  #
  # Pure and side-effect free: no DB reads or writes, no policy lookups.
  class CalendarTimeCalculator
    # Shares the `elapsed(from, to)` signature with Sla::BusinessHoursCalculator so Step 2.6 can
    # select a calculator by coverage mode and call it uniformly. Returns 0 for nil endpoints or
    # a non-positive span (never negative).
    def elapsed(from, to)
      return 0 if from.nil? || to.nil?

      seconds = to.to_time.to_f - from.to_time.to_f
      seconds.negative? ? 0 : seconds.round
    end
  end
end
