# frozen_string_literal: true

module Sla
  # Phase 2 · Step 2.3 — Business-hours elapsed calculation.
  #
  # Computes the elapsed WORKING time, in whole seconds, between two events using a business
  # calendar (working weekdays, daily working window, holidays). This is what a
  # `coverage_hours = 'business_hours'` SLA measures. It is the highest-bug-risk component of
  # the engine, so the logic is kept deliberately simple and exhaustively unit-tested.
  #
  # Algorithm: walk each calendar date the span touches; for every working day (a configured
  # working weekday that is not a holiday) intersect the span [from, to] with that day's
  # working window [start, end] and sum the overlaps. Time outside the window, whole
  # non-working days (weekends), and holidays contribute nothing.
  #
  # Windows are built with the calendar's time zone via `TimeZone#local`, so the working hours
  # track wall-clock local time across DST (a working day containing a spring-forward is one
  # real hour shorter, which is correct). Absolute-instant subtraction then yields real seconds.
  #
  # Pure and side-effect free: it reads only the duck-typed calendar passed in (any object
  # responding to #working_days, #work_start_time, #work_end_time, #holidays — e.g.
  # SlaBusinessCalendar) and never touches the database.
  class BusinessHoursCalculator
    # @param calendar [#working_days, #work_start_time, #work_end_time, #holidays]
    #   working_days: ISO weekday numbers (1 = Mon .. 7 = Sun); work_*_time: 'HH:MM' strings;
    #   holidays: Date objects or 'YYYY-MM-DD' strings.
    # @param zone [ActiveSupport::TimeZone] the calendar's zone (default: the app zone, falling
    #   back to UTC for a bare-Ruby/console caller that hasn't set Time.zone).
    def initialize(calendar, zone: Time.zone || ActiveSupport::TimeZone['UTC'])
      @zone           = zone
      @working_days   = Array(calendar.working_days).map(&:to_i)
      @holidays       = Array(calendar.holidays).map { |h| to_date(h) }
      @start_h, @start_m = parse_hhmm(calendar.work_start_time)
      @end_h,   @end_m   = parse_hhmm(calendar.work_end_time)
    end

    # Shares the `elapsed(from, to)` signature with Sla::CalendarTimeCalculator. Returns 0 for
    # nil endpoints, a non-positive span, or a calendar with no working window defined.
    def elapsed(from, to)
      return 0 if from.nil? || to.nil? || @start_h.nil? || @end_h.nil?

      from = from.in_time_zone(@zone)
      to   = to.in_time_zone(@zone)
      return 0 if to <= from

      total = 0.0
      date  = from.to_date
      last  = to.to_date

      # O(days-in-span): fine at plugin scale (a sweep is thousands of issues x weeks). Only
      # worth replacing with whole-week bulk math if ever reused to project over long horizons.
      while date <= last
        if working_day?(date)
          overlap_start = [from, window_start(date)].max
          overlap_end   = [to,   window_end(date)].min
          total += (overlap_end - overlap_start) if overlap_end > overlap_start
        end
        date += 1
      end

      total.round
    end

    private

    def working_day?(date)
      @working_days.include?(date.cwday) && !@holidays.include?(date)
    end

    def window_start(date)
      @zone.local(date.year, date.month, date.day, @start_h, @start_m)
    end

    def window_end(date)
      @zone.local(date.year, date.month, date.day, @end_h, @end_m)
    end

    def parse_hhmm(value)
      return [nil, nil] if value.blank?

      hours, minutes = value.to_s.split(':')
      [hours.to_i, minutes.to_i]
    end

    def to_date(value)
      value.is_a?(Date) ? value : Date.parse(value.to_s)
    end
  end
end
