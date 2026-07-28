# frozen_string_literal: true

# Data source for the SLA Policy settings tab. The tab partial renders inside
# ProjectsController#settings (no plugin controller runs on that GET), so everything the form
# needs is derived here. All lists come live from Redmine configuration — never constants.
module SlaPoliciesHelper
  # --- Sectioned settings shell -------------------------------------------------------------
  # The tab is split into sidebar-navigable sections instead of one long scrolling form. Section
  # keys are the single source of truth shared by the nav, the panels, each section form's hidden
  # `section` field and SlaPoliciesController#update (which uses them to decide WHICH slice of the
  # policy a submit is allowed to touch) — keep them in sync with
  # SlaPoliciesController::POLICY_SECTIONS.
  #
  # :permission is the permission that must be held for the section to be offered at all; the four
  # policy sections share :edit_sla_policy, Notifications is gated separately (as it always was).
  SECTIONS = [
    { key: 'general',       permission: :edit_sla_policy },
    { key: 'measurement',   permission: :edit_sla_policy },
    { key: 'targets',       permission: :edit_sla_policy },
    { key: 'exclusions',    permission: :edit_sla_policy },
    { key: 'notifications', permission: :manage_sla_notifications }
  ].freeze

  # B3 — [source_project, source_policy] when this project's CONFIGURATION comes from an ANCESTOR
  # (so the tab shows the read-only inherited banner instead of an editable form), else nil.
  # `clone_from` present means Override was just pressed and we're mid AJAX re-render into the real
  # edit form, so it takes precedence.
  #
  # Deliberately `config_source_for`, not `source_for`: a project holding a LIGHTWEIGHT row (its
  # own SLA on/off decision, everything else inherited — see SlaPolicy#inherits_config?) still has
  # no configuration to edit, so it must keep showing the ancestor's banner.
  def sla_inherited_policy_source(project)
    return nil if params[:clone_from].present?

    source_project, source_policy = SlaPolicy.config_source_for(project)
    return nil if source_project.nil? || source_project == project

    [source_project, source_policy]
  end

  # Tri-state SLA on/off shown on the inherited banner: :inherit / :enabled / :disabled for this
  # project, plus whether SLA actually ends up on — so "Inherit" can say WHICH state it inherits.
  def sla_enablement_state(project)
    SlaPolicy.enablement_for(project)
  end

  # What "Inherit" resolves to right now, i.e. the nearest ANCESTOR's decision — computed by
  # asking the parent, so a lightweight row on this project doesn't answer its own question.
  def sla_inherited_enablement_on?(project)
    SlaPolicy.effective_for(project.parent).present?
  end

  # +inherited+: an inherited policy has no editable policy sections, so only Notifications is
  # offered until Override turns the banner into the real form.
  def sla_visible_sections(project, inherited: false)
    SECTIONS.select do |section|
      next false if inherited && section[:permission] == :edit_sla_policy

      User.current.allowed_to?(section[:permission], project)
    end
  end

  # Section the page opens on: the requested one when it exists and is permitted, else the first
  # permitted section (a notifications-only manager lands on Notifications, not a hidden General).
  # Takes the already-computed list so the permission checks run once per request, not per caller.
  def sla_current_section(sections)
    keys = sections.map { |section| section[:key] }
    requested = params[:section].presence
    keys.include?(requested) ? requested : keys.first
  end

  def sla_section_label(key)
    l(:"label_sla_section_#{key}")
  end

  def sla_section_description(key)
    l(:"text_sla_section_#{key}")
  end

  # Feather-style 24×24 outline icons for the sidebar, keyed by section. Static developer-authored
  # markup (no user data), hence html_safe; `currentColor` lets the nav's active/inactive text
  # colour drive the icon colour with no extra classes.
  SECTION_ICON_PATHS = {
    'general' => '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.6a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
    'measurement' => '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
    'targets' => '<circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2"/>',
    'exclusions' => '<circle cx="12" cy="12" r="10"/><line x1="10" y1="15" x2="10" y2="9"/><line x1="14" y1="15" x2="14" y2="9"/>',
    'notifications' => '<path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/>'
  }.freeze

  def sla_section_icon(key)
    paths = SECTION_ICON_PATHS[key]
    return ''.html_safe if paths.nil?

    ('<svg class="tw-w-5 tw-h-5 tw-shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' \
     'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' \
     "#{paths}</svg>").html_safe
  end

  # Floppy-disk glyph shown on every section's primary save button (matches the design).
  def sla_save_icon
    sla_inline_icon('<path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/>' \
                    '<polyline points="17 21 17 13 7 13 7 21"/><polyline points="7 3 7 8 15 8"/>')
  end

  # Two-sheets glyph on the Clone Policy "Load" button.
  def sla_copy_icon
    sla_inline_icon('<rect x="9" y="9" width="13" height="13" rx="2"/>' \
                    '<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>')
  end

  # Circled "i" leading the amber unclassified-priority notice.
  def sla_info_icon
    sla_inline_icon('<circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/>' \
                    '<line x1="12" y1="8" x2="12.01" y2="8"/>')
  end

  # Shared 16×16 outline-icon wrapper. The path strings above are static developer-authored markup
  # (no user data), which is what makes html_safe correct here; `currentColor` lets the surrounding
  # text colour drive the stroke.
  def sla_inline_icon(paths, size_classes = 'tw-w-4 tw-h-4 tw-shrink-0')
    ("<svg class=\"#{size_classes}\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" " \
     'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' \
     "#{paths}</svg>").html_safe
  end

  # The policy shown in the form: a controller-provided one (validation failure / clone
  # prefill), the saved row, or a fresh record whose DB defaults give a sensible blank form.
  def sla_policy_for_form(project)
    @sla_policy ||= SlaPolicy.find_by(project_id: project.id) ||
                    SlaPolicy.new(project_id: project.id)
  end

  # Status IDs selected for a milestone role, read from the in-memory association so unsaved
  # clone prefills render too.
  def sla_status_ids(policy, role)
    policy.sla_status_mappings.select { |m| m.role == role.to_s }.map(&:status_id)
  end

  # priority_id => SlaDefinition for one tracker, from the in-memory association.
  def sla_definition_map(policy, tracker)
    return {} unless tracker
    policy.sla_definitions.select { |d| d.tracker_id == tracker.id }.index_by(&:priority_id)
  end

  # The tracker whose target rows are displayed: explicit request param, else the first
  # tracker that already has definitions, else the project's first tracker.
  def sla_selected_tracker(project, policy)
    trackers = project.trackers.to_a
    requested = params[:tracker_id].presence
    trackers.detect { |t| t.id == requested.to_i } ||
      trackers.detect { |t| policy.sla_definitions.any? { |d| d.tracker_id == t.id } } ||
      trackers.first
  end

  # <option> list for one target dropdown: a leading "not tracked" blank, then the admin lookup
  # (numeric durations by seconds, Best Effort rows by the 'best_effort' sentinel — a Best Effort
  # option has no seconds value to use as the option value). If the saved numeric value no longer
  # matches any option (the admin edited the lookup), inject it so it isn't silently dropped on
  # the next save.
  SLA_BEST_EFFORT_VALUE = 'best_effort'

  def sla_target_select_options(target_type, current_seconds, current_best_effort = false)
    rows = sla_target_options_by_type.fetch(target_type.to_s, [])
    options = rows.reject(&:best_effort?).map { |o| [o.label, o.seconds.to_s] }
    options += rows.select(&:best_effort?).map { |o| [o.label, SLA_BEST_EFFORT_VALUE] }

    if !current_best_effort && current_seconds.present? &&
       options.none? { |_, value| value == current_seconds.to_s }
      options.unshift([l(:label_sla_target_current_value,
                         value: format_sla_duration(current_seconds)), current_seconds.to_s])
    end
    options.unshift([l(:label_sla_target_skipped), ''])

    selected = current_best_effort ? SLA_BEST_EFFORT_VALUE : (current_seconds || '').to_s
    options_for_select(options, selected)
  end

  def sla_target_options_by_type
    @sla_target_options_by_type ||=
      SlaTargetOption.order(:position, :seconds).group_by(&:target_type)
  end

  # Is this the admin-designated "None / unclassified" priority (Administration → Plugins →
  # SLA Compliance)? Always excluded from SLA Definitions — see Sla::PolicyContext#definition_for.
  def sla_unclassified_priority?(priority_id)
    priority_id.present? && priority_id == Sla::PluginSettings.unclassified_priority_id
  end

  # The configured unclassified priority itself, or nil when none is designated. Drives the amber
  # notice above the Priority Targets table (the row it replaces).
  def sla_unclassified_priority
    return @sla_unclassified_priority if defined?(@sla_unclassified_priority)

    id = Sla::PluginSettings.unclassified_priority_id
    @sla_unclassified_priority = id.present? ? IssuePriority.active.detect { |p| p.id == id } : nil
  end

  # --- B3: read-only display for the "inherited from an ancestor" banner ---------------------
  # Plain text, not form pre-population — see _inherited_banner.html.erb for why this is
  # deliberately NOT the same interactive form partial used for an owned policy.

  def sla_status_names(policy, role)
    ids = sla_status_ids(policy, role)
    return l(:label_sla_target_skipped) if ids.empty?

    IssueStatus.where(id: ids).order(:position).pluck(:name).join(', ')
  end

  # One summary line per priority that has a definition on +tracker+, e.g.
  # "High — Response: 1h, Workaround: —, Resolution: Best Effort".
  def sla_target_summary_lines(policy, tracker)
    return [] unless tracker

    definitions = sla_definition_map(policy, tracker)
    IssuePriority.active.filter_map do |priority|
      definition = definitions[priority.id]
      next if definition.nil?

      parts = SlaDefinition::TARGET_TYPES.map do |type|
        "#{sla_target_type_label(type)}: #{sla_target_summary_value(definition, type)}"
      end
      "#{priority.name} — #{parts.join(', ')}"
    end
  end

  def sla_target_summary_value(definition, type)
    return l(:field_sla_best_effort) if definition.best_effort?(type)

    seconds = definition.public_send("#{type}_seconds")
    seconds.present? ? format_sla_duration(seconds) : l(:label_sla_target_skipped)
  end

  # Source candidates for "Clone from another project": projects the user could edit the
  # policy of, that actually have one — minus the current project.
  def sla_clone_source_projects(project)
    Project.active.allowed_to(:edit_sla_policy)
           .where(id: SlaPolicy.select(:project_id))
           .where.not(id: project.id)
           .sorted
  end

  # Notification settings shown in the tab's second section (4.6).
  def sla_notification_setting_for_form(project)
    @sla_notification_setting ||= SlaNotificationSetting.find_by(project_id: project.id) ||
                                  SlaNotificationSetting.new(project_id: project.id)
  end

  # Shared Flowbite control classes (single source, per CLAUDE.md — don't re-type per field).
  def sla_input_classes
    'tw-bg-gray-50 tw-border tw-border-gray-300 tw-text-gray-900 tw-text-sm tw-rounded-lg ' \
      'focus:tw-ring-primary-500 focus:tw-border-primary-500 tw-block tw-w-full tw-p-2.5'
  end

  def sla_label_classes
    'tw-block tw-mb-2 tw-text-sm tw-font-medium tw-text-gray-900'
  end

  def sla_radio_classes
    'tw-w-4 tw-h-4 tw-text-primary-600 tw-border-gray-300 focus:tw-ring-primary-500'
  end

  # Primary submit button — one definition for every section's save action.
  #
  # No `focus:tw-ring-*` here: measured in the browser, Purplemine2's own `button:focus` box-shadow
  # beat those utilities on plain buttons, so the ring they promise never actually painted. The
  # focus ring for every button in the plugin is declared once, unambiguously, in
  # partials/_theme_isolation.css instead — see the note there.
  def sla_primary_button_classes
    'tw-inline-flex tw-items-center tw-gap-2 tw-text-white tw-bg-primary-600 ' \
      'hover:tw-bg-primary-700 tw-border-0 tw-font-medium ' \
      'tw-rounded-lg tw-text-sm tw-px-5 tw-py-2.5 tw-cursor-pointer'
  end

  # Neutral outlined button (Clone "Load", "Revert to inherited policy") — deliberately never blue,
  # so the primary colour stays reserved for the one save action per section (Global Rule 7).
  def sla_secondary_button_classes
    'tw-inline-flex tw-items-center tw-gap-2 tw-text-gray-900 tw-bg-white tw-border ' \
      'tw-border-solid tw-border-gray-300 hover:tw-bg-gray-100 ' \
      'tw-font-medium tw-rounded-lg tw-text-sm tw-px-4 tw-py-2.5 tw-cursor-pointer'
  end
end
