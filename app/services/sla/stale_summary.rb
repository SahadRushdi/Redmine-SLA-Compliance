# frozen_string_literal: true

module Sla
  # Dashboard "Stale" card: OPEN tickets in the given sla_results scope that have had no updates for
  # at least their project's configured inactivity threshold. "No updates" is measured off
  # issues.updated_on — Redmine bumps that on any note, status change, or edit, which is exactly the
  # "no any changes" the card reports.
  #
  # The threshold is PER PROJECT and inherited down the tree (Step 6.2a): each project's own value,
  # else the nearest ancestor's, else the instance-wide default — resolved for the whole scope in
  # two queries by Sla::StaleThresholds. A multi-project scope therefore applies each project's own
  # cutoff, via an OR of (project_id, cutoff) pairs, rather than measuring every row against one
  # ruler.
  #
  # UNCONFIGURED ⇒ NOT A NUMBER. When no project in scope resolves to a threshold, the result is
  # `configured? == false` and the card renders an em dash instead of 0: "nobody has said what stale
  # means here" and "nothing is stale" are different statements, and 0 asserts the second. A project
  # in a mixed scope that has no threshold simply contributes nothing to the count.
  #
  # A cache/DB-only read (Global Rule 4): one aggregate query over the already-filtered relation,
  # never the per-ticket timeline reconstruction Sla::StaleTicketDetector does for the sweep.
  #
  # "Open" is `sla_results.resolved_at IS NULL` — the plugin's own definition (not in a configured
  # `resolved`-role status), the same one Sla::DashboardScope#open_only applies, so the Stale card
  # and the Total Open Tickets card always describe the same population. A resolved ticket that
  # simply hasn't been touched since is not "stale", it's done. Kept here rather than relying on the
  # caller's scope because other callers pass an unfiltered relation.
  class StaleSummary
    # `configured` answers "does a threshold apply anywhere in this scope", which is what decides
    # whether the card shows a count at all — it is not derivable from `count`, since a configured
    # scope with nothing idle also counts 0.
    Result = Struct.new(:count, :configured, keyword_init: true) do
      def configured?
        !!configured
      end
    end

    def self.call(scope:, now: Time.current, thresholds: nil)
      new(scope: scope, now: now, thresholds: thresholds).call
    end

    # @param thresholds [Hash{Integer=>Integer}, nil] project_id => days; resolved from the scope's
    #   own projects when nil. Injectable so the service stays unit-testable with no policy rows.
    def initialize(scope:, now: Time.current, thresholds: nil)
      @scope      = scope
      @now        = now
      @thresholds = thresholds
    end

    def call
      base        = open_scope
      project_ids = base.distinct.pluck(:project_id)
      thresholds  = @thresholds || StaleThresholds.for_projects(project_ids)
      applicable  = thresholds.slice(*project_ids).compact

      return Result.new(count: 0, configured: false) if applicable.empty?

      Result.new(count: base.where(stale_condition(applicable)).count, configured: true)
    end

    private

    def open_scope
      @scope.reorder(nil).unscope(:includes).joins(:issue).where(sla_results: { resolved_at: nil })
    end

    # One "(project_id = ? AND issues.updated_on <= ?)" clause per project that has a threshold,
    # each using that project's own cutoff, OR'd together — so a single COUNT resolves the whole
    # (possibly multi-project) scope with the correct threshold applied to each row. Projects
    # without one contribute no clause and so no rows.
    def stale_condition(thresholds)
      thresholds.map { |project_id, days|
        # `<=`, not `<`: matches Sla::StaleTicketDetector's inclusive `inactive_seconds >= threshold`
        # boundary, so a ticket idle for exactly the threshold counts as stale in both paths.
        ActiveRecord::Base.sanitize_sql_array(
          ['(sla_results.project_id = ? AND issues.updated_on <= ?)', project_id, @now - days.to_i.days]
        )
      }.join(' OR ')
    end
  end
end
