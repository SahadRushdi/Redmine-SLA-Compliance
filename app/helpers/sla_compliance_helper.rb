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

  SLA_CARD_COLOR_CLASSES = {
    total: 'tw-bg-primary-50 tw-text-primary-700 tw-border-primary-200',
    met: 'tw-bg-green-50 tw-text-green-700 tw-border-green-200',
    breached: 'tw-bg-red-50 tw-text-red-700 tw-border-red-200',
    at_risk: 'tw-bg-amber-50 tw-text-amber-700 tw-border-amber-200',
    no_sla: 'tw-bg-gray-50 tw-text-gray-700 tw-border-gray-200'
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

  # --- Step 6.3: chart colors ----------------------------------------------------------------

  # Real Tableau 10 hex values (Global Rule 7), chosen so the compliance-state colors
  # simultaneously match the summary cards' semantic palette (green/red/orange/gray) and the
  # trend chart's Created line matches CLAUDE.md's explicit "#4E79A7 is intentional chart data
  # encoding" callout. Resolved deliberately uses a color (teal) not already carrying
  # compliance-state meaning elsewhere on the page.
  SLA_CHART_COLORS = {
    met: '#59A14F', at_risk: '#F28E2B', breached: '#E15759', no_sla: '#BAB0AC',
    created: '#4E79A7', resolved: '#76B7B2'
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

    if filters[:tracker_id]
      tracker = available_trackers.detect { |t| t.id == filters[:tracker_id] }
      chips << { label: tracker.name, url: sla_dashboard_url_without(filters, project, :tracker_id, nil) } if tracker
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

  # Every state-tab / sort-header / pagination link in the detail table goes through this, so the
  # active project/tracker/priority/date filters are always carried forward - same mechanism as
  # the chip URLs above (sla_dashboard_query_params), not a second one.
  def sla_detail_table_url(filters, project, state: nil, sort: nil, sort_dir: nil, page: nil)
    query = sla_dashboard_query_params(filters)
              .merge(state: state, sort: sort, sort_dir: sort_dir, page: page)
              .reject { |_, v| v.blank? }

    project ? project_sla_dashboard_index_path(project, query) : sla_dashboard_cross_project_path(query)
  end

  private

  def sla_dashboard_query_params(filters)
    {
      project_ids: filters[:project_ids],
      tracker_id: filters[:tracker_id],
      priority_ids: filters[:priority_ids],
      date_preset: filters[:date_preset],
      from: filters[:date_range]&.first,
      to: filters[:date_range]&.last
    }
  end

  def sla_dashboard_url_without(filters, project, key, value)
    query = sla_dashboard_query_params(filters)
    case key
    when :project_ids, :priority_ids then query[key] = Array(query[key]) - [value]
    when :tracker_id then query[:tracker_id] = nil
                           query[:priority_ids] = []
    when :date_preset then query[:date_preset] = nil
                            query[:from] = nil
                            query[:to] = nil
    end
    query = query.reject { |_, v| v.blank? }

    project ? project_sla_dashboard_index_path(project, query) : sla_dashboard_cross_project_path(query)
  end
end
