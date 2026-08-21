# frozen_string_literal: true

# Shared formatting helpers for the plugin (single place for duration/time formatting,
# per the CLAUDE.md convention).
module SlaComplianceHelper
  # Scan-friendly human form of a duration in seconds. Precision decreases as the duration grows:
  # seconds below one minute, minutes below one hour, hours/minutes below one day, days/hours below
  # one week, weeks/days below 30 days, then whole days. Days are 24h calendar days — target
  # options are absolute durations, not working time.
  def format_sla_duration(seconds)
    return '' if seconds.blank?

    seconds = seconds.to_i
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m" if seconds < 3600

    if seconds < 86_400
      hours, remainder = seconds.divmod(3600)
      minutes = remainder / 60
      return ["#{hours}h", ("#{minutes}m" if minutes.positive?)].compact.join(' ')
    end

    days, remainder = seconds.divmod(86_400)
    if days < 7
      hours = remainder / 3600
      return ["#{days}d", ("#{hours}h" if hours.positive?)].compact.join(' ')
    end

    if days < 30
      weeks, remaining_days = days.divmod(7)
      return ["#{weeks}w", ("#{remaining_days}d" if remaining_days.positive?)].compact.join(' ')
    end

    "#{days}d"
  end

  # Label for a target type / milestone role from the plugin enum value.
  def sla_target_type_label(type)
    l("label_sla_target_#{type}")
  end

  # --- Step 6.2: summary cards ---------------------------------------------------------------

  # ONE hue per SLA state, used identically wherever that state appears (summary card surface,
  # icon tile, headline number, detail-table result badge). SLA states carry a distinct hue —
  # no_sla is violet rather than grey because it is routinely the LARGEST bucket on the board
  # (~80% of tickets on an unconfigured project), and a grey tile reads as "disabled/empty" for
  # what is actually the dashboard's biggest number. Stale uses violet because inactivity is an
  # activity signal rather than an SLA verdict; it stays distinct from total's blue, met's green,
  # at_risk's amber and breached's red while remaining visible on the gray page canvas.
  #
  # Every map below spells its utilities out in full rather than interpolating a hue name into
  # `tw-bg-#{hue}-50`: Tailwind's content scanner matches literal class strings in these files, so
  # an interpolated name is never compiled and the class silently renders unstyled.

  # Tinted card surface: -50 fill with a -200 border. The border is only one step up from the fill
  # (not -300) because the tiles sit on the gray-50 page canvas, where a heavier outline reads as a
  # warning rather than as a boundary.
  SLA_CARD_SURFACE_CLASSES = {
    total: 'tw-bg-primary-50 tw-border-primary-200',
    met: 'tw-bg-green-50 tw-border-green-200',
    breached: 'tw-bg-red-50 tw-border-red-200',
    at_risk: 'tw-bg-amber-50 tw-border-amber-200',
    no_sla: 'tw-bg-violet-50 tw-border-violet-200',
    stale: 'tw-bg-violet-50 tw-border-violet-200'
  }.freeze

  def sla_card_surface_classes(state)
    SLA_CARD_SURFACE_CLASSES.fetch(state.to_sym)
  end

  # Headline number colour. `total` is the one exception to "number takes the state hue": it is a
  # neutral count, not a verdict, so it stays near-black and the state/activity cards beside it
  # keep colour as a meaningful signal instead of decoration.
  SLA_CARD_VALUE_CLASSES = {
    total: 'tw-text-gray-900', met: 'tw-text-green-600', breached: 'tw-text-red-600',
    at_risk: 'tw-text-amber-600', no_sla: 'tw-text-violet-600', stale: 'tw-text-violet-600'
  }.freeze

  def sla_card_value_classes(state)
    SLA_CARD_VALUE_CLASSES.fetch(state.to_sym)
  end

  # Result badges in the ticket-level detail table: same hue as the card, -50 fill / -700 text so
  # the badge stays legible at 12px. Kept separate from the card surface because a badge needs a
  # text colour and no border, and the card needs the reverse.
  SLA_CARD_COLOR_CLASSES = {
    total: 'tw-bg-primary-50 tw-text-primary-700 tw-border-primary-300',
    met: 'tw-bg-green-50 tw-text-green-700 tw-border-green-300',
    breached: 'tw-bg-red-50 tw-text-red-700 tw-border-red-300',
    at_risk: 'tw-bg-amber-50 tw-text-amber-700 tw-border-amber-300',
    no_sla: 'tw-bg-violet-50 tw-text-violet-700 tw-border-violet-300',
    stale: 'tw-bg-violet-50 tw-text-violet-700 tw-border-violet-300'
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

    ((count.to_f / total) * 100).round
  end

  # Icon-tile background/text tint per card state - one step darker than the card's own pastel
  # surface (SLA_CARD_SURFACE_CLASSES) so the icon reads clearly against it.
  SLA_CARD_ICON_CLASSES = {
    total: 'tw-bg-primary-100 tw-text-primary-600',
    met: 'tw-bg-green-100 tw-text-green-600',
    breached: 'tw-bg-red-100 tw-text-red-600',
    at_risk: 'tw-bg-amber-100 tw-text-amber-600',
    no_sla: 'tw-bg-violet-100 tw-text-violet-600',
    stale: 'tw-bg-violet-100 tw-text-violet-600'
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
            '<line x1="6.5" y1="17.5" x2="17.5" y2="6.5" stroke-width="2" stroke-linecap="round"/>',
    # Clock — stale is a time-since-last-activity signal.
    stale: '<circle cx="12" cy="12" r="9" stroke-width="2"/>' \
           '<polyline points="12,7 12,12 15.5,14" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/>'
  }.freeze

  def sla_card_icon(state)
    inner = SLA_CARD_ICONS.fetch(state.to_sym)
    "<svg class=\"tw-w-5 tw-h-5\" fill=\"none\" stroke=\"currentColor\" viewBox=\"0 0 24 24\" aria-hidden=\"true\">#{inner}</svg>".html_safe
  end

  # --- Step 6.3: chart colors ----------------------------------------------------------------

  # DEVIATION FROM GLOBAL RULE 7, recorded deliberately. The implementation plan specifies the
  # Tableau 10 palette for charts, and these were its real hex values (#59A14F / #F28E2B /
  # #E15759 / #BAB0AC). The approved dashboard design supplies its own chart palette instead, so
  # these now match it — which has the side benefit of making a state EXACTLY the same colour in
  # the chart as on its summary card and its detail-table badge, rather than a muted Tableau
  # cousin of it. Raise it if the plan should be amended.
  #
  # Every state is the -600 hue of its SLA_CARD_VALUE_CLASSES entry, no_sla included. no_sla was
  # previously gray-300 here (violet only on the card) on the theory that a saturated violet would
  # swamp the arcs that carry a real verdict — but in practice the grey read as "missing data" in
  # the legends and dots, and disagreed with the violet card for the same number. One hue per
  # state everywhere wins over that: the mapping is now identical on the card, the badge, and
  # every chart segment/legend dot on the page.
  SLA_CHART_COLORS = {
    met: '#16a34a',      # green-600
    at_risk: '#d97706',  # amber-600
    breached: '#dc2626', # red-600
    no_sla: '#d1d5db'    # gray-300
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

  # --- Step 6.3: trend chart granularity ------------------------------------------------------

  # Single source of truth for the valid granularity values, shared by the controller (validating
  # params[:granularity]) and this helper (rendering the pill group) — see
  # Sla::TrendSeries::GRANULARITIES.
  def sla_granularities
    Sla::TrendSeries::GRANULARITIES
  end

  def sla_granularity_label(granularity)
    l("label_sla_granularity_#{granularity}")
  end

  # --- Step 6.4: detail table -----------------------------------------------------------------

  # Numeric rank for the detail table's client-side "Result" sort, derived from the SAME live
  # effective state the badge shows (met on-track < met at-risk < breached < no_sla) so the sort
  # order matches what the row displays.
  def sla_result_sort_rank(sla_result)
    case sla_result.effective_primary_state
    when 'breached' then 2
    when 'no_sla'   then 3
    else sla_result.effective_at_risk? ? 1 : 0
    end
  end

  # The detail table's own link back to this page, carrying the active project/tracker/priority/date
  # filters forward - same mechanism as the chip URLs above (sla_dashboard_query_params), not a
  # second one. `format: 'csv'` is how the Export CSV button reuses this exact builder instead of a
  # separate one: same filters, just a different response format.
  #
  # It used to take state/sort/sort_dir/page/q/per_page too, back when each of those controls was a
  # server link. Every one of them filters, sorts or paginates the rendered rows in place now
  # (sla_dashboard_detail_table.js), so nothing builds a URL from them any more and the parameters
  # went with them. The CONTROLLER still reads ?state= and ?q= — a bookmarked link and a CSV export
  # both still work — it is only the link-building side that is gone.
  def sla_detail_table_url(filters, project, format: nil)
    query = sla_dashboard_query_params(filters).merge(format: format).reject { |_, v| v.blank? }

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
      from: sla_date_param(filters[:date_range]&.first),
      to: sla_date_param(filters[:date_range]&.last)
    }
  end

  # Serialize a date for the from/to query params in the same mm/dd/yyyy format the custom-range
  # inputs display and the controller parses — so a link round-trips through resolve_filters.
  def sla_date_param(date)
    date&.strftime('%m/%d/%Y')
  end
end
