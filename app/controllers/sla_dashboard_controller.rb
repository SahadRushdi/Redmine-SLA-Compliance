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
class SlaDashboardController < ApplicationController
  before_action :find_project_by_project_id, only: :index
  before_action :authorize, only: :index
  before_action :set_permitted_projects, only: :index
  before_action :authorize_cross_project, only: :cross_project

  helper :sla_compliance
  helper :sla_policies # reuses sla_input_classes/sla_label_classes for the filter bar's fields

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
    @scope  = Sla::DashboardScope.call(project_ids: @filters[:project_ids], tracker_id: @filters[:tracker_id],
                                        priority_ids: @filters[:priority_ids], date_range: @filters[:date_range])
    @counts = Sla::ResultSummary.call(scope: @scope)

    # Step 6.3 — charts. Both read the same filtered @scope; no live SLA computation, only
    # aggregation over the sla_results cache (Global Rule 4).
    @priority_breakdown = Sla::PriorityBreakdown.call(scope: @scope)
    @trend              = Sla::TrendSeries.call(scope: @scope, date_range: @filters[:date_range])

    # Step 6.4 — detail table.
    build_detail_table

    render :index
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
    tracker_id = params[:tracker_id].presence&.to_i
    tracker_id = nil unless @available_trackers.map(&:id).include?(tracker_id)

    @available_priorities = tracker_id ? configured_priorities(project_ids, tracker_id) : IssuePriority.none
    priority_ids = Array(params[:priority_ids]).map(&:to_i) & @available_priorities.map(&:id)

    date_preset = params[:date_preset].presence
    date_preset = 'this_week' unless DATE_PRESETS.include?(date_preset)

    @filters = {
      project_ids: project_ids,
      tracker_id: tracker_id,
      priority_ids: priority_ids,
      date_preset: date_preset,
      date_range: resolve_date_range(date_preset, params[:from], params[:to])
    }
  end

  # Union of configured trackers/priorities across the distinct effective policies among the
  # given projects - usually one policy, but a multi-project selection can span several via
  # per-project inheritance (Global Rule 5).
  def configured_trackers(project_ids)
    tracker_ids = effective_policies(project_ids).flat_map { |p| p.sla_definitions.distinct.pluck(:tracker_id) }.uniq
    Tracker.where(id: tracker_ids).sorted
  end

  def configured_priorities(project_ids, tracker_id)
    priority_ids = effective_policies(project_ids).flat_map do |p|
      p.sla_definitions.where(tracker_id: tracker_id).distinct.pluck(:priority_id)
    end.uniq - [Sla::PluginSettings.unclassified_priority_id]
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

  # Date._parse is a non-raising probe (unlike Date.parse) so a malformed custom date never 500s
  # the page - falls back to no date filter, same as an unrecognized preset.
  def custom_date_range(from, to)
    parsed_from = Date._parse(from.to_s).present? ? Date.parse(from) : nil
    parsed_to   = Date._parse(to.to_s).present?   ? Date.parse(to)   : nil
    return nil if parsed_from.nil? || parsed_to.nil? || parsed_from > parsed_to

    parsed_from..parsed_to
  end

  # --- Step 6.4: detail table -----------------------------------------------------------------

  DETAIL_STATES = %w[all met breached at_risk no_sla].freeze
  DETAIL_SORT_COLUMNS = {
    'ticket'         => 'issues.id',
    'project'        => 'projects.name',
    'tracker'        => 'trackers.name',
    'title'          => 'issues.subject',
    'status'         => 'issue_statuses.position',
    'assignee'       => 'users.lastname',
    'first_response' => 'sla_results.response_seconds',
    'resolution'     => 'sla_results.resolution_seconds',
    'result'         => Sla::EffectiveState::ORDER_RANK_SQL,
    'deviation'      => 'sla_results.deviation_seconds'
  }.freeze

  # State tabs and their counts come straight from @counts (already computed for the summary
  # cards) - no second aggregate query. Sort/state-filter/pagination params are clamped the same
  # way resolve_filters clamps the main filters: an invalid value silently falls back to the
  # default rather than 403ing or erroring.
  def build_detail_table
    @state_filter   = DETAIL_STATES.include?(params[:state]) ? params[:state] : 'all'
    @sort_column    = DETAIL_SORT_COLUMNS.key?(params[:sort]) ? params[:sort] : 'ticket'
    @sort_direction = %w[asc desc].include?(params[:sort_dir]) ? params[:sort_dir] : 'desc'

    total_count = @state_filter == 'all' ? @counts.total : @counts.public_send(@state_filter)
    @detail_pages = Redmine::Pagination::Paginator.new(total_count, per_page_option, params[:page])

    base = @scope.joins(issue: %i[project tracker status]).left_joins(issue: :assigned_to)
    base = apply_state_filter(base, @state_filter)

    # sanitize_sql_array is required even for plain column names here (not just ORDER_RANK_SQL,
    # the one column expression that actually contains a :now bind placeholder) - passed a
    # `now:` hash unconditionally so this stays correct if a future sort column ever needs a
    # bind too; sanitize_sql_array leaves a string with no matching placeholder untouched.
    column_sql = ActiveRecord::Base.sanitize_sql_array([DETAIL_SORT_COLUMNS[@sort_column], now: Time.current])
    order_sql  = "#{column_sql} #{@sort_direction == 'desc' ? 'DESC' : 'ASC'}"
    @detail_results = base.reorder(Arel.sql(order_sql))
                          .limit(@detail_pages.per_page).offset(@detail_pages.offset)
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
    when 'no_sla'   then scope.where(Sla::EffectiveState::EFFECTIVE_NO_SLA)
    else scope
    end
  end
end
