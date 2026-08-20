# SLA compliance dashboard (Phase 6, Steps 6.1-6.2). Reads only from the `sla_results` cache
# (Global Rule 4) via Sla::DashboardScope + Sla::ResultSummary — never computes SLA state here.
#
# Two contexts, one shared template (see #render_dashboard / views/sla_dashboard/index.html.erb):
#   #index         - project-level, /projects/:project_id/sla_dashboard, locked to the current
#                    project's subtree.
#   #cross_project - top-level, /sla_dashboard, spans every SLA-enabled project the user can see.
#
# find_project_by_project_id/authorize (core ApplicationController) require @project and cannot
# run for the project-less #cross_project action, so that action gets its own bespoke permission
# check (there is no single global :view_sla_dashboard permission to authorize against, only a
# per-project one - see SlaPolicy.enabled_projects_for).
require 'csv'

class SlaDashboardController < ApplicationController
  # Which registered menu entry Redmine should render as SELECTED while this controller is acting.
  #
  # Without these, Redmine::MenuManager::MenuController#current_menu_item falls back to
  # `menu_items[controller_name][:default]`, which defaults to the CONTROLLER NAME — :sla_dashboard.
  # Neither menu entry is called that (init.rb registers the project tab as :sla_compliance and the
  # cross-project entry as :sla_dashboard_all, deliberately distinct so their dasherized CSS classes
  # don't collide), so nothing ever matched and the "SLA Compliance" project tab never highlighted
  # while you were standing on it. The names below must stay in step with init.rb's `menu` calls.
  menu_item :sla_compliance
  menu_item :sla_dashboard_all, only: :cross_project

  before_action :find_project_by_project_id, only: :index
  before_action :authorize, only: :index
  before_action :set_permitted_projects, only: :index
  before_action :authorize_cross_project, only: :cross_project

  helper :sla_compliance
  helper :sla_policies # reuses sla_input_classes/sla_label_classes for the filter bar's fields
  include SlaComplianceHelper # reused for the CSV export's cell formatting (format_sla_duration, sla_card_label)

  def index
    render_dashboard
  end

  def cross_project
    render_dashboard
  end

  private

  # Project-level: current project + descendants only (never the full cross-project universe) -
  # locked to a single, non-editable selection when there are no descendants.
  def set_permitted_projects
    @permitted_projects = SlaPolicy.enabled_projects_for(User.current, base_scope: @project.self_and_descendants)
    @locked_project = @permitted_projects.size <= 1
  end

  # Top-level: every SLA-enabled, visible, permitted project. 403s (or redirects to login) when
  # the user has no permitted project anywhere - mirrors what the :application_menu :if proc in
  # init.rb already checked to decide whether to show the link at all.
  def authorize_cross_project
    @permitted_projects = SlaPolicy.enabled_projects_for(User.current)
    return deny_access if @permitted_projects.empty?

    @locked_project = false
  end

  def render_dashboard
    resolve_filters

    # The Open Tickets tab counts OPEN tickets — not resolved, per the policy's own `resolved`-role
    # statuses — at all times, ignoring the selected date range entirely. A ticket breaching its
    # SLA is a live problem whether it was raised this week or last quarter, so hiding it behind a
    # date filter would understate the backlog. Everything on that tab (summary cards, Stale card,
    # priority/donut charts, detail table) reads this same @scope.
    @scope  = Sla::DashboardScope.call(project_ids: @filters[:project_ids], tracker_ids: @filters[:tracker_ids],
                                        priority_ids: @filters[:priority_ids], open_only: true)
    @counts = Sla::ResultSummary.call(scope: @scope)
    # Carries `configured?` as well as the count: with no threshold set on any project in scope the
    # card renders "not configured" rather than a 0 (Sla::StaleSummary).
    @stale = Sla::StaleSummary.call(scope: @scope)

    # Step 6.3 — charts. Reads the same current-state @scope; no live SLA computation, only
    # aggregation over the sla_results cache (Global Rule 4).
    @priority_breakdown = Sla::PriorityBreakdown.call(scope: @scope)

    # The Trend tab is period-scoped. Its SLA Met denominator contains only evaluated tickets whose
    # policy-derived resolution milestone falls inside the selected period. Open tickets are not
    # final outcomes and therefore cannot inflate historical compliance as provisionally "met".
    trend_scope = Sla::DashboardScope.call(project_ids: @filters[:project_ids], tracker_ids: @filters[:tracker_ids],
                                            priority_ids: @filters[:priority_ids])
    resolved_period_scope = Sla::DashboardScope.call(
      project_ids: @filters[:project_ids], tracker_ids: @filters[:tracker_ids],
      priority_ids: @filters[:priority_ids], resolved_range: @filters[:date_range]
    )
    @trend_counts = Sla::ResultSummary.call(scope: resolved_period_scope)
    trend_detail_scope = Sla::DashboardScope.call(
      project_ids: @filters[:project_ids], tracker_ids: @filters[:tracker_ids],
      priority_ids: @filters[:priority_ids], trend_detail_range: @filters[:date_range]
    )
    @trend_detail_counts = Sla::ResultSummary.call(scope: trend_detail_scope)

    # Created and Resolved use independent milestone timestamps so an older cycle resolved during
    # this period still appears on the Resolved line without appearing on the Created line.
    @trend_series = Sla::TrendSeries.call(scope: trend_scope, date_range: @filters[:date_range],
                                          granularity: @filters[:granularity])

    # Step 6.4 — two independently interactive detail tables. Open Tickets keeps the current
    # backlog scope; SLA Trend combines unresolved cycles started in the period with resolved
    # outcomes completed in the period.
    build_detail_tables(trend_detail_scope)

    respond_to do |format|
      format.html { render :index }
      format.csv  { send_detail_csv }
    end
  end

  # Never trusts client-submitted project/tracker/priority ids - always intersects against what
  # the current context actually permits/configures. An out-of-set value is silently clamped
  # (dropped back to the permitted/configured default), not 403ed, matching how Redmine's own
  # filter/report pages handle a stale or tampered query string.
  #
  # Also sets @available_trackers/@available_priorities (real Tracker/IssuePriority objects, not
  # just ids) so the filter bar's <select> options are computed once here, not re-derived by the
  # view or duplicated into a helper.
  def resolve_filters
    permitted_ids = @permitted_projects.map(&:id)
    project_ids = Array(params[:project_ids]).map(&:to_i) & permitted_ids
    project_ids = permitted_ids if project_ids.empty?

    @available_trackers = configured_trackers(project_ids)
    tracker_ids = Array(params[:tracker_ids]).map(&:to_i) & @available_trackers.map(&:id)

    @available_priorities = tracker_ids.any? ? configured_priorities(project_ids, tracker_ids) : IssuePriority.none
    priority_ids = Array(params[:priority_ids]).map(&:to_i) & @available_priorities.map(&:id)

    date_preset = params[:date_preset].presence
    date_preset = 'this_week' unless DATE_PRESETS.include?(date_preset)

    granularity = params[:granularity].presence
    granularity = 'daily' unless Sla::TrendSeries::GRANULARITIES.include?(granularity)

    @filters = {
      project_ids: project_ids,
      tracker_ids: tracker_ids,
      priority_ids: priority_ids,
      date_preset: date_preset,
      date_range: resolve_date_range(date_preset, params[:from], params[:to]),
      granularity: granularity
    }
  end

  # Union of configured trackers/priorities across the distinct effective policies among the
  # given projects - usually one policy, but a multi-project selection can span several via
  # per-project inheritance (Global Rule 5).
  def configured_trackers(project_ids)
    tracker_ids = effective_policies(project_ids).flat_map { |p| p.sla_definitions.distinct.pluck(:tracker_id) }.uniq
    Tracker.where(id: tracker_ids).sorted
  end

  # Union of the priorities configured across every selected tracker (a multi-tracker selection
  # can span several via per-project inheritance).
  def configured_priorities(project_ids, tracker_ids)
    priority_ids = effective_policies(project_ids).flat_map do |p|
      p.sla_definitions.where(tracker_id: tracker_ids).distinct.pluck(:priority_id)
    end.uniq
    IssuePriority.where(id: priority_ids).sorted
  end

  def effective_policies(project_ids)
    Project.where(id: project_ids).filter_map { |p| SlaPolicy.effective_for(p) }.uniq
  end

  DATE_PRESETS = %w[this_week last_week this_month last_month last_3_months custom].freeze

  # "Last 3 Months" is a rolling calendar-month window (1st of the month 3 months back through the
  # end of the current month), consistent with This/Last Month's calendar-month semantics - not a
  # rolling 90-day window.
  def resolve_date_range(preset, from, to)
    today = Time.zone.today

    case preset
    when 'this_week'     then today.beginning_of_week..today.end_of_week
    when 'last_week'     then (today - 1.week).beginning_of_week..(today - 1.week).end_of_week
    when 'this_month'    then today.beginning_of_month..today.end_of_month
    when 'last_month'    then (today - 1.month).beginning_of_month..(today - 1.month).end_of_month
    when 'last_3_months' then (today - 3.months).beginning_of_month..today.end_of_month
    when 'custom'        then custom_date_range(from, to)
    end
  end

  def custom_date_range(from, to)
    parsed_from = parse_filter_date(from)
    parsed_to   = parse_filter_date(to)
    return nil if parsed_from.nil? || parsed_to.nil? || parsed_from > parsed_to

    parsed_from..parsed_to
  end

  # Parses the mm/dd/yyyy the custom-range inputs submit (matching the My Time picker), tolerating
  # ISO yyyy-mm-dd for any link-carried/legacy value. Never raises on a malformed value — returns
  # nil so the page falls back to no date filter instead of 500ing, same as an unrecognized preset.
  def parse_filter_date(value)
    string = value.to_s.strip
    return nil if string.blank?

    ['%m/%d/%Y', '%Y-%m-%d'].each do |format|
      return Date.strptime(string, format)
    rescue ArgumentError
      next
    end
    nil
  end

  # --- Step 6.4: detail table -----------------------------------------------------------------

  DETAIL_STATES = %w[all met breached at_risk].freeze

  # State tabs, sorting and pagination are ALL handled client-side (sla_dashboard_detail_table.js)
  # over the rows rendered here — no page reload for any of them. Only the main filters still
  # resubmit as plain GET, since they change which tickets are in scope at all. `state` and `q` are
  # still read here (and clamped the way resolve_filters clamps the main filters, an invalid value
  # falling back to the default) so a bookmarked ?state=breached link still opens on that pill and a
  # CSV export of one state still works.
  #
  # @detail_results is the row set the HTML table renders in one shot, deliberately covering EVERY
  # state: the pills filter it in place, so the rows they filter to have to already be on the page.
  # Bounded by Redmine's own export-size setting so a pathological scope can't emit an unbounded
  # page. @detail_scope is the state-filtered relation CSV export reads — an export has no client to
  # do the filtering, so that one stays server-side.
  def build_detail_tables(trend_detail_scope)
    @state_filter = DETAIL_STATES.include?(params[:state]) ? params[:state] : 'all'
    @search_query = params[:q].to_s.strip.presence

    open_base = detail_relation(@scope)
    open_base = apply_search_filter(open_base, @search_query)

    @detail_results       = open_base.limit(Setting.issues_export_limit.to_i)
    @detail_scope         = apply_state_filter(open_base, @state_filter)
    @trend_detail_results = detail_relation(trend_detail_scope).limit(Setting.issues_export_limit.to_i)
  end

  def detail_relation(scope)
    scope.joins(issue: %i[project tracker status])
         .left_joins(issue: :assigned_to)
         .reorder('issues.id DESC')
         .includes(issue: %i[project tracker status assigned_to])
  end

  # Reuses the exact same effective-state definition as the summary cards (Sla::EffectiveState) -
  # a state-tab filter can never disagree with the counts shown just above the table.
  def apply_state_filter(scope, state)
    now = Time.current
    case state
    when 'met'      then scope.where(Sla::EffectiveState::EFFECTIVE_MET, now: now)
    when 'breached' then scope.where(Sla::EffectiveState::EFFECTIVE_BREACHED, now: now)
    when 'at_risk'  then scope.where(Sla::EffectiveState::EFFECTIVE_AT_RISK, now: now, at_risk_true: true)
    else scope
    end
  end

  # Matches ticket subject (substring) or an exact ticket id (with or without a leading '#').
  def apply_search_filter(scope, query)
    return scope if query.blank?

    ticket_id = query[/\A#?(\d+)\z/, 1]
    if ticket_id
      scope.where('issues.subject LIKE :like OR issues.id = :id', like: "%#{query}%", id: ticket_id.to_i)
    else
      scope.where('issues.subject LIKE :like', like: "%#{query}%")
    end
  end

  # --- Export CSV -------------------------------------------------------------------------------

  # Every matching row (ignores pagination), same filters/state/search/sort as the HTML table.
  # Capped by Redmine's own export-size setting (Setting.issues_export_limit) rather than a
  # plugin-specific limit - reuses the admin's existing safety bound instead of inventing a
  # second one.
  def send_detail_csv
    send_data(detail_csv, type: 'text/csv; header=present', filename: detail_csv_filename)
  end

  def detail_csv
    CSV.generate do |csv|
      csv << [l(:field_sla_detail_ticket), l(:field_sla_detail_project), l(:field_sla_detail_tracker),
              l(:field_sla_detail_title), l(:field_sla_detail_status), l(:field_sla_detail_assignee),
              l(:field_sla_detail_first_response), l(:field_sla_detail_resolution),
              l(:field_sla_detail_result), l(:field_sla_detail_deviation)]

      @detail_scope.limit(Setting.issues_export_limit.to_i).each do |sla_result|
        csv << detail_csv_row(sla_result)
      end
    end
  end

  def detail_csv_row(sla_result)
    issue = sla_result.issue
    state = sla_result.effective_primary_state
    deviation = sla_result.effective_deviation_seconds
    result_label = sla_card_label(state.to_sym)
    result_label = "#{result_label} (#{l(:label_sla_card_at_risk)})" if sla_result.effective_at_risk?

    response_duration = sla_result.completed_response_seconds
    resolution_duration = sla_result.completed_resolution_seconds

    [issue.id, issue.project.name, issue.tracker.name, issue.subject, issue.status.name,
     issue.assigned_to&.name,
     response_duration.present? ? format_sla_duration(response_duration) : '-',
     resolution_duration.present? ? format_sla_duration(resolution_duration) : '-', result_label,
     deviation.present? ? format_sla_duration(deviation) : nil]
  end

  def detail_csv_filename
    scope_part = @project ? @project.identifier : 'all-projects'
    "sla-compliance-#{scope_part}-#{Date.current.iso8601}.csv"
  end
end
