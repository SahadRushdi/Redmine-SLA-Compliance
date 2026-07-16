# frozen_string_literal: true

module Sla
  # Step 6.3 — Created-vs-Resolved trend. Buckets by day, week, and month simultaneously in one
  # call so the dashboard's Daily/Weekly/Monthly toggle is a pure client-side re-render (the same
  # two date columns, re-aggregated) — no extra query-string param, no page reload.
  #
  # Never uses DB-specific date-trunc SQL (Redmine supports MySQL/PostgreSQL/SQLite3) — plucks raw
  # issues.created_on / sla_results.resolved_at pairs from the already-filtered
  # Sla::DashboardScope relation and buckets them in Ruby via ActiveSupport.
  #
  # Both series share the SAME date_range window: a ticket resolved after the filtered range
  # contributes 0 to Resolved for this call (even though the ticket itself, via its created_on,
  # is inside the filtered scope) — keeps Created and Resolved on one directly comparable X-axis
  # rather than letting Resolved trail off past where Created stops.
  class TrendSeries
    Point  = Struct.new(:label, :created, :resolved, keyword_init: true)
    Series = Struct.new(:daily, :weekly, :monthly, keyword_init: true)

    EMPTY = Series.new(daily: [], weekly: [], monthly: []).freeze

    def self.call(scope:, date_range:, now: Time.current)
      new(scope: scope, date_range: date_range, now: now).call
    end

    def initialize(scope:, date_range:, now: Time.current)
      @scope      = scope
      @date_range = date_range
      @now        = now
    end

    def call
      return EMPTY if @date_range.nil?

      pairs = @scope.reorder(nil).unscope(:includes).pluck('issues.created_on', 'sla_results.resolved_at')
      Series.new(daily: bucket(pairs, :day), weekly: bucket(pairs, :week), monthly: bucket(pairs, :month))
    end

    private

    def bucket(pairs, granularity)
      created  = Hash.new(0)
      resolved = Hash.new(0)

      pairs.each do |created_on, resolved_at|
        tally(created, created_on, granularity)
        tally(resolved, resolved_at, granularity)
      end

      bucket_sequence(granularity).map do |key|
        Point.new(label: label_for(key, granularity), created: created[key], resolved: resolved[key])
      end
    end

    def tally(counts, time, granularity)
      return if time.nil?

      date = time.to_date
      return unless @date_range.cover?(date)

      counts[bucket_key(date, granularity)] += 1
    end

    def bucket_key(date, granularity)
      case granularity
      when :day   then date
      when :week  then date.beginning_of_week
      when :month then date.beginning_of_month
      end
    end

    # One key per bucket spanning the whole date_range, even where both counts are 0 — so the
    # trend line has no gaps within the selected window.
    def bucket_sequence(granularity)
      case granularity
      when :day
        (@date_range.first..@date_range.last).to_a
      when :week
        step_dates(@date_range.first.beginning_of_week, @date_range.last.beginning_of_week) { |d| d + 7 }
      when :month
        step_dates(@date_range.first.beginning_of_month, @date_range.last.beginning_of_month) { |d| d.next_month }
      end
    end

    def step_dates(from, to)
      dates = []
      date = from
      while date <= to
        dates << date
        date = yield(date)
      end
      dates
    end

    def label_for(key, granularity)
      case granularity
      when :day   then key.strftime('%b %-d')
      when :week  then key.strftime('%b %-d')
      when :month then key.strftime('%b %Y')
      end
    end
  end
end
