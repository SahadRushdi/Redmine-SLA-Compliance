# frozen_string_literal: true

# Shell for the plugin's ADMIN configuration module (Administration → SLA Compliance).
#
# Everything an admin configures for this plugin used to be three disconnected pages: the plugin
# settings form, plus two lookup CRUD screens reachable only through inline text links on it, with
# no way back except the browser's Back button. This helper makes them one module with one
# persistent sidebar, mirroring the project-level SLA Policy tab (SlaPoliciesHelper::SECTIONS) so
# the two configuration surfaces read as the same product.
#
# The one structural difference from the project tab: there, every section is a slice of ONE record
# and all the panels can live in one page. Here two of the four sections are separate CRUD
# resources with their own controllers, routes and forms, and Redmine hosts the settings form
# inside its own <form> (app/views/settings/plugin.html.erb) — forms cannot nest. So:
#
#   general / access             -> panels on the plugin settings page, swapped client-side
#   target_options / calendars   -> their own pages, rendering this same shell and sidebar
#
# Which means the sidebar is present and correct on every page of the module either way, which was
# the actual complaint. `panel?` below is what tells the two apart.
module SlaAdminHelper
  # Order here IS the sidebar order. Keys are the single source of truth shared by the nav, the
  # panels, the section query param and sla_admin.js — do not rename one without the others.
  #
  # :panel marks a section that lives as a hidden/shown panel on the plugin settings page rather
  # than at a URL of its own. General leads because it is where an admin lands with nothing
  # configured; the two lookups follow in the order the policy form consumes them.
  SECTIONS = [
    { key: 'general',            panel: true },
    { key: 'access',             panel: true },
    { key: 'target_options',     panel: false },
    { key: 'business_calendars', panel: false }
  ].freeze

  # The sections rendered as panels on the settings page, in sidebar order. Used by that page to
  # decide what to render and which panel opens; kept derived rather than a second literal list.
  PANEL_KEYS = SECTIONS.select { |s| s[:panel] }.map { |s| s[:key] }.freeze

  def sla_admin_sections
    SECTIONS
  end

  def sla_admin_panel_keys
    PANEL_KEYS
  end

  # Which panel the settings page opens on. Falls back to the first panel section, so a stale or
  # hand-typed ?section= can never leave the page with nothing visible.
  def sla_admin_current_panel
    requested = params[:section].presence
    PANEL_KEYS.include?(requested) ? requested : PANEL_KEYS.first
  end

  # Where a sidebar entry points. The panel sections share the settings page URL and differ only by
  # ?section=, which is also the no-JS fallback: without JavaScript the link is a real navigation
  # and the server opens that panel (see #sla_admin_current_panel).
  def sla_admin_section_path(key)
    case key
    when 'target_options'     then sla_target_options_path
    when 'business_calendars' then sla_business_calendars_path
    else sla_settings_path(section: key)
    end
  end

  def sla_admin_section_label(key)
    l(:"label_sla_admin_section_#{key}")
  end

  def sla_admin_section_description(key)
    l(:"text_sla_admin_section_#{key}")
  end

  # Feather-style 24×24 outline icons, keyed by section — same convention (and same rendering
  # helper) as the project tab's sidebar, so the two navs are visually identical. Static
  # developer-authored markup, no user data, which is what makes SlaPoliciesHelper#sla_inline_icon's
  # html_safe correct here too.
  SECTION_ICON_PATHS = {
    'general' => SlaPoliciesHelper::SECTION_ICON_PATHS['general'],
    'access' => '<path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/>' \
                '<path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
    'target_options' => SlaPoliciesHelper::SECTION_ICON_PATHS['targets'],
    'business_calendars' => '<rect x="3" y="4" width="18" height="18" rx="2"/>' \
                            '<line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/>' \
                            '<line x1="3" y1="10" x2="21" y2="10"/>'
  }.freeze

  def sla_admin_section_icon(key)
    sla_inline_icon(SECTION_ICON_PATHS.fetch(key, ''), 'tw-w-5 tw-h-5 tw-shrink-0')
  end

  # --- Shared chrome ---------------------------------------------------------------------------

  # Plus glyph on the "New …" buttons above the two lookup tables.
  def sla_add_icon
    sla_inline_icon('<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>')
  end

  # Pencil / trash glyphs for a table row's actions. 14px rather than the 16px default: they sit
  # inside a 28px icon button in a dense table row.
  def sla_edit_icon
    sla_inline_icon('<path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/>' \
                    '<path d="M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4z"/>',
                    'tw-w-3.5 tw-h-3.5 tw-shrink-0')
  end

  def sla_delete_icon
    sla_inline_icon('<polyline points="3 6 5 6 21 6"/>' \
                    '<path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
                    'tw-w-3.5 tw-h-3.5 tw-shrink-0')
  end

  # Badge for an enumerated value shown in a table cell (target type, basis). Neutral grey by
  # design: these are classifications, not states, and Global Rule 7 reserves blue for UI chrome.
  def sla_admin_badge(text)
    content_tag :span, text,
                class: 'tw-inline-flex tw-items-center tw-rounded-md tw-bg-gray-100 ' \
                       'tw-px-2 tw-py-0.5 tw-text-xs tw-font-medium tw-text-gray-700'
  end

  # Shared table classes, defined once so the two lookup tables cannot drift apart.
  def sla_admin_table_classes
    'tw-w-full tw-text-sm tw-text-left tw-text-gray-700'
  end

  # Title case only — never uppercased via CSS (CLAUDE.md).
  # Header cells only. Body cells are styled by CSS (`.sla-admin-rows td`, see
  # partials/_admin_settings.css), not by a matching helper, because the access allow-list's rows
  # are re-rendered by sla_access_form.js and must not need a copy of these class strings.
  def sla_admin_th_classes
    'tw-px-4 tw-py-3 tw-font-medium tw-text-gray-700 tw-whitespace-nowrap'
  end

  # ISO weekday number (1 = Monday … 7 = Sunday, as stored) → localised day name. Redmine's own
  # day_name expects 0 = Sunday, hence the modulo — kept here so the two calendar views and any
  # future caller share one conversion instead of re-deriving it.
  def sla_weekday_name(iso_day)
    day_name(iso_day.to_i % 7)
  end

  # Short form ("Mon") for the working-days pills, where seven full names would not fit a row.
  def sla_weekday_abbr(iso_day)
    ::I18n.t('date.abbr_day_names')[iso_day.to_i % 7]
  end
end
