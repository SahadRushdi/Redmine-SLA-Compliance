# frozen_string_literal: true

module Sla
  # Phase 2 · Step 2.8 — Stale-ticket detection.
  #
  # For a ticket EXCLUDED from SLA (no_sla — unclassified priority or unset target), computes the
  # time since its last activity, where activity is any comment (public OR private — an internal
  # note still means someone touched the ticket) or status change. Falls back to the creation
  # time when there has been no activity at all.
  #
  # Inactivity is measured as calendar (wall-clock) time — "no activity for N days" is a
  # real-world duration, independent of business hours. Pure and side-effect free.
  class StaleTicketDetector
    ACTIVITY_TYPES = %i[status_change comment].freeze

    def initialize(timeline, now: Time.current)
      @timeline = timeline
      @now      = now
      @calendar = CalendarTimeCalculator.new
    end

    def last_activity_at
      activity = @timeline.events.select { |event| ACTIVITY_TYPES.include?(event.type) }
      activity.map(&:at).max || @timeline.created_event&.at
    end

    def inactive_seconds(now: @now)
      @calendar.elapsed(last_activity_at, now)
    end

    def stale?(threshold_seconds, now: @now)
      inactive_seconds(now: now) >= threshold_seconds
    end
  end
end
