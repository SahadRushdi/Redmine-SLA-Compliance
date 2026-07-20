# frozen_string_literal: true

# Shared formatting helpers for the plugin (single place for duration/time formatting,
# per the CLAUDE.md convention).
module SlaComplianceHelper
  # Compact human form of a duration in seconds: "30m", "4h", "1d 4h 30m".
  # Days are 24h calendar days — target options are absolute durations, not working time.
  def format_sla_duration(seconds)
    return '' if seconds.blank?

    seconds = seconds.to_i
    days, rem = seconds.divmod(86_400)
    hours, rem = rem.divmod(3600)
    minutes = rem / 60

    parts = []
    parts << "#{days}d" if days.positive?
    parts << "#{hours}h" if hours.positive?
    parts << "#{minutes}m" if minutes.positive?
    parts << "#{seconds}s" if parts.empty?
    parts.join(' ')
  end

  # Label for a target type / milestone role from the plugin enum value.
  def sla_target_type_label(type)
    l("label_sla_target_#{type}")
  end

  # --- Step 6.2: summary cards ---------------------------------------------------------------

  # Border one step more saturated than the pastel fill (-300 vs -50 bg) so each card reads as a
  # clearly delineated tile against the near-white page, matching the reference design.
  SLA_CARD_COLOR_CLASSES = {
    total: 'tw-bg-primary-50 tw-text-primary-700 tw-border-primary-300',
    met: 'tw-bg-green-50 tw-text-green-700 tw-border-green-300',
    breached: 'tw-bg-red-50 tw-text-red-700 tw-border-red-300',
    at_risk: 'tw-bg-amber-50 tw-text-amber-700 tw-border-amber-300',
    no_sla: 'tw-bg-gray-50 tw-text-gray-700 tw-border-gray-300'
  }.freeze

  def sla_card_color_classes(state)
    SLA_CARD_COLOR_CLASSES.fetch(state.to_sym)
  end

  # Title Case per project convention — never uppercased via CSS (CLAUDE.md).
  def sla_card_label(state)
    l("label_sla_card_#{state}")
  end

  def sla_percentage(count, total)
    return 0 if total.to_i.zero?

    ((count.to_f / total) * 100).round(1)
  end

  # Icon-circle background/text tint per card state - one step darker than the card's own pastel
  # background (SLA_CARD_COLOR_CLASSES) so the icon reads clearly against it.
  SLA_CARD_ICON_CLASSES = {
    total: 'tw-bg-primary-100 tw-text-primary-700',
    met: 'tw-bg-green-100 tw-text-green-700',
    breached: 'tw-bg-red-100 tw-text-red-700',
    at_risk: 'tw-bg-amber-100 tw-text-amber-700',
    no_sla: 'tw-bg-gray-200 tw-text-gray-700'
  }.freeze

  def sla_card_icon_classes(state)
    SLA_CARD_ICON_CLASSES.fetch(state.to_sym)
  end

  # Simple, deliberately basic (rect/circle/line/polyline) inline SVGs - purely decorative, so a
  # slightly imperfect shape is a non-issue, but a malformed path attribute would render nothing;
  # basic primitives keep that risk near zero.
  SLA_CARD_ICONS = {
    total: '<rect x="5" y="3" width="14" height="18" rx="2" stroke-width="2"/>' \
           '<line x1="8" y1="8" x2="16" y2="8" stroke-width="2"/>' \
           '<line x1="8" y1="12" x2="16" y2="12" stroke-width="2"/>' \
           '<line x1="8" y1="16" x2="12" y2="16" stroke-width="2"/>',
    met: '<circle cx="12" cy="12" r="9" stroke-width="2"/>' \
         '<polyline points="8,12.5 10.5,15 16,9" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/>',
    breached: '<path d="M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6l7-3z" stroke-width="2" stroke-linejoin="round"/>' \
              '<line x1="12" y1="9" x2="12" y2="13" stroke-width="2" stroke-linecap="round"/>' \
              '<circle cx="12" cy="16" r="0.75" fill="currentColor" stroke="none"/>',
    at_risk: '<path d="M12 4l9 15H3L12 4z" stroke-width="2" stroke-linejoin="round"/>' \
             '<line x1="12" y1="10" x2="12" y2="14" stroke-width="2" stroke-linecap="round"/>' \
             '<circle cx="12" cy="17" r="0.75" fill="currentColor" stroke="none"/>',
    no_sla: '<circle cx="12" cy="12" r="9" stroke-width="2"/>' \
            '<line x1="6.5" y1="17.5" x2="17.5" y2="6.5" stroke-width="2" stroke-linecap="round"/>'
  }.freeze

  def sla_card_icon(state)
    inner = SLA_CARD_ICONS.fetch(state.to_sym)
    "<svg class=\"tw-w-5 tw-h-5\" fill=\"none\" stroke=\"currentColor\" viewBox=\"0 0 24 24\" aria-hidden=\"true\">#{inner}</svg>".html_safe
  end

  # --- Step 6.3: chart colors ----------------------------------------------------------------

  # Real Tableau 10 hex values (Global Rule 7), chosen so the compliance-state colors
  # simultaneously match the summary cards' semantic palette (green/red/orange/gray).
  SLA_CHART_COLORS = {
    met: '#59A14F', at_risk: '#F28E2B', breached: '#E15759', no_sla: '#BAB0AC'
  }.freeze

  def sla_chart_color(key)
    SLA_CHART_COLORS.fetch(key.to_sym)
  end

  # --- Step 6.1: filter bar chips ------------------------------------------------------------

  def sla_dashboard_base_path(project)
    project ? project_sla_dashboard_index_path(project) : sla_dashboard_cross_project_path
  end

  # Single source of truth for the valid preset values, shared by the controller (validating
  # params[:date_preset]) and this helper (rendering the <select> options) — see
  # SlaDashboardController::DATE_PRESETS.
  def sla_date_presets
    SlaDashboardController::DATE_PRESETS
  end

  def sla_date_preset_label(preset)
    l("label_sla_date_preset_#{preset}")
  end

  # One removable chip per non-default active filter: individually selected projects (only shown
  # once the selection has been narrowed below "every permitted project" — the unnarrowed default
  # isn't an "active filter" worth a chip), the selected tracker, each selected priority, and the
  # date range when it isn't the default preset.
  def sla_dashboard_chips(filters, project:, permitted_projects:, available_trackers:, available_priorities:, locked_project:)
    chips = []

    unless locked_project
      selected = permitted_projects.select { |p| filters[:project_ids].include?(p.id) }
      if selected.size < permitted_projects.size
        selected.each do |proj|
          chips << { label: proj.name, url: sla_dashboard_url_without(filters, project, :project_ids, proj.id) }
        end
      end
    end

    filters[:tracker_ids].each do |tid|
      tracker = available_trackers.detect { |t| t.id == tid }
      chips << { label: tracker.name, url: sla_dashboard_url_without(filters, project, :tracker_ids, tid) } if tracker
    end

    filters[:priority_ids].each do |pid|
      priority = available_priorities.detect { |p| p.id == pid }
      chips << { label: priority.name, url: sla_dashboard_url_without(filters, project, :priority_ids, pid) } if priority
    end

    if filters[:date_preset] != 'this_week' || filters[:date_range]
      chips << { label: sla_date_preset_label(filters[:date_preset]),
                 url: sla_dashboard_url_without(filters, project, :date_preset, nil) }
    end

    chips
  end

  # --- Step 6.4: detail table -----------------------------------------------------------------

  # Every state-tab / sort-header / search / per-page / pagination / export link in the detail
  # table goes through this, so the active project/tracker/priority/date filters are always
  # carried forward - same mechanism as the chip URLs above (sla_dashboard_query_params), not a
  # second one. `format: 'csv'` is how the Export CSV button reuses this exact link builder
  # instead of a separate one - same filters/state/search/sort, just a different response format.
  def sla_detail_table_url(filters, project, state: nil, sort: nil, sort_dir: nil, page: nil,
                           q: nil, per_page: nil, format: nil)
    query = sla_dashboard_query_params(filters)
              .merge(state: state, sort: sort, sort_dir: sort_dir, page: page, q: q, per_page: per_page,
                     format: format)
              .reject { |_, v| v.blank? }

    project ? project_sla_dashboard_index_path(project, query) : sla_dashboard_cross_project_path(query)
  end

  # A concise "Nov 01 – Nov 30, 2025" style label for the header subtitle, resolved from the same
  # date_range the filters/charts/table all already use - never re-derives it.
  def sla_dashboard_date_range_label(date_range)
    return sla_date_preset_label('custom') if date_range.nil?

    from, to = date_range.first, date_range.last
    same_year = from.year == to.year
    from_format = same_year ? '%b %d' : '%b %d, %Y'
    "#{from.strftime(from_format)} – #{to.strftime('%b %d, %Y')}"
  end

  private

  def sla_dashboard_query_params(filters)
    {
      project_ids: filters[:project_ids],
      tracker_ids: filters[:tracker_ids],
      priority_ids: filters[:priority_ids],
      date_preset: filters[:date_preset],
      from: filters[:date_range]&.first,
      to: filters[:date_range]&.last
    }
  end

  def sla_dashboard_url_without(filters, project, key, value)
    query = sla_dashboard_query_params(filters)
    case key
    # Removing a tracker leaves priority_ids untouched — resolve_filters re-clamps them against the
    # remaining trackers' priorities (and drops them all if the last tracker is removed).
    when :project_ids, :priority_ids, :tracker_ids then query[key] = Array(query[key]) - [value]
    when :date_preset then query[:date_preset] = nil
                            query[:from] = nil
                            query[:to] = nil
    end
    query = query.reject { |_, v| v.blank? }

    project ? project_sla_dashboard_index_path(project, query) : sla_dashboard_cross_project_path(query)
  end
end
