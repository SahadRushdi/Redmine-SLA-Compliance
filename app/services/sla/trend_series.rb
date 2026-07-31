# frozen_string_literal: true

module Sla
  # Step 6.3 — Created-vs-Resolved trend series (dual line, Daily/Weekly/Monthly) for the
  # dashboard's trend chart. Reads only from `sla_results`/`issues` (Global Rule 4: no live SLA
  # computation) and buckets in Ruby rather than SQL DATE()/DATE_TRUNC(), to stay portable across
  # Redmine's three supported DB adapters (MySQL/PostgreSQL/SQLite) — the same reasoning
  # Sla::PriorityBreakdown gives for avoiding a fragile cross-adapter multi-column pluck.
  #
  # `scope:` must be a Sla::DashboardScope-built relation with NO date_range filter applied
  # (project/tracker/priority only — call DashboardScope.call(..., date_range: nil)). Reusing the
  # controller's already date-filtered @scope (which filters on issues.created_on) would silently
  # exclude issues created outside the window but resolved inside it. Created and Resolved are
  # therefore filtered against `date_range` independently here, each against its own timestamp
  # column (issues.created_on / sla_results.resolved_at), not by reusing one shared filtered scope.
  #
  # `resolved_at` (migration 004) is nullable and lazily backfilled — only populated the next time
  # an issue is recomputed by the event hook, sweep, or a historical recalc. Older cached rows may
  # therefore undercount the Resolved line until they're next touched; this is a known limitation
  # of the precomputed cache, not something this service can correct by reading further back.
  class TrendSeries
    GRANULARITIES = %w[daily weekly monthly].freeze

    Point = Struct.new(:bucket_start, :bucket_label, :created, :resolved, keyword_init: true)

    def self.call(scope:, date_range:, granularity: 'daily', now: Time.current)
      new(scope: scope, date_range: date_range, granularity: granularity, now: now).call
    end

    def initialize(scope:, date_range:, granularity: 'daily', now: Time.current)
      @scope = scope
      @date_range = date_range
      @granularity = GRANULARITIES.include?(granularity) ? granularity : 'daily'
      @now = now
    end

    def call
      return [] if @date_range.nil?

      created_counts  = bucket_counts(created_dates)
      resolved_counts = bucket_counts(resolved_dates)

      bucket_starts.map do |bucket_start|
        Point.new(bucket_start: bucket_start, bucket_label: label_for(bucket_start),
                  created: created_counts.fetch(bucket_start, 0),
                  resolved: resolved_counts.fetch(bucket_start, 0))
      end
    end

    private

    def created_dates
      @scope.reorder(nil).unscope(:includes)
            .where(issues: { created_on: timestamp_range })
            .pluck('issues.created_on')
    end

    def resolved_dates
      @scope.reorder(nil).unscope(:includes)
            .where.not(resolved_at: nil)
            .where(resolved_at: timestamp_range)
            .pluck(:resolved_at)
    end

    # A Date..Date range compared directly against a datetime column is NOT widened to cover the
    # whole last day by ActiveRecord/the DB adapter here — `BETWEEN '2026-07-01' AND '2026-07-01'`
    # casts both bounds to midnight, silently excluding everything after 00:00:00 on the last day.
    # Build the full-day datetime bounds explicitly instead of relying on that (absent) expansion.
    def timestamp_range
      @date_range.first.beginning_of_day..@date_range.last.end_of_day
    end

    def bucket_counts(timestamps)
      timestamps.each_with_object(Hash.new(0)) do |timestamp, counts|
        counts[bucket_key(timestamp.to_date)] += 1
      end
    end

    def bucket_key(date)
      case @granularity
      when 'weekly'  then date.beginning_of_week
      when 'monthly' then date.beginning_of_month
      else date
      end
    end

    # Every bucket across the full date_range, including ones with zero activity, so the line
    # chart doesn't show a misleading gap for an empty day/week/month.
    def bucket_starts
      cursor = bucket_key(@date_range.first)
      last   = bucket_key(@date_range.last)

      starts = []
      while cursor <= last
        starts << cursor
        cursor = advance(cursor)
      end
      starts
    end

    def advance(bucket_start)
      case @granularity
      when 'weekly'  then bucket_start + 1.week
      when 'monthly' then bucket_start.next_month
      else bucket_start + 1.day
      end
    end

    def label_for(bucket_start)
      @granularity == 'monthly' ? bucket_start.strftime('%b %Y') : bucket_start.strftime('%b %-d')
    end
  end
end
