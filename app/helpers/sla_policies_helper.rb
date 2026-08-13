# frozen_string_literal: true

# Data source for the SLA Policy settings tab. The tab partial renders inside
# ProjectsController#settings (no plugin controller runs on that GET), so everything the form
# needs is derived here. All lists come live from Redmine configuration — never constants.
module SlaPoliciesHelper
  def sla_notification_recipient_options(project, selected_ids)
    users = (project ? Sla::ProjectRecipientUsers.for(project) : User.active.joins(:email_address))
            .distinct.order(:lastname, :firstname, :id)
    options_for_select(users.map { |user| ["#{user.name} — #{user.mail}", user.id] }, selected_ids)
  end
  # --- Sectioned settings shell -------------------------------------------------------------
  # The tab is split into sidebar-navigable sections instead of one long scrolling form. Section
  # keys are the single source of truth shared by the nav, the panels, each section form's hidden
  # `section` field and SlaPoliciesController#update (which uses them to decide WHICH slice of the
  # policy a submit is allowed to touch) — keep them in sync with
  # SlaPoliciesController::POLICY_SECTIONS.
  #
  # :permission is the permission that must be held for the section to be offered at all; the four
  # policy sections share :edit_sla_policy, Notifications is gated separately (as it always was).
  # Order here IS the sidebar order, and the first entry is where the tab opens
  # (see #sla_current_section). SLA Targets sits above Measurement Rules because it is the section
  # people come back to; the measurement rules are set once and rarely revisited.
  SECTIONS = [
    { key: 'general',       permission: :edit_sla_policy },
    { key: 'targets',       permission: :edit_sla_policy },
    { key: 'measurement',   permission: :edit_sla_policy },
    { key: 'notifications', permission: :manage_sla_notifications }
  ].freeze

  # B3 — [source_project, source_policy] when this project's CONFIGURATION comes from an ANCESTOR,
  # else nil. The tab renders the same editable sections either way (see #sla_policy_for_form); this
  # only decides whether the inheritance notice and the tri-state on/off control appear above them.
  # `clone_from` present means a clone source was just loaded and the form now shows THAT, so the
  # inheritance notice would be describing something no longer on screen.
  #
  # Deliberately `config_source_for`, not `source_for`: a project holding a LIGHTWEIGHT row (its
  # own SLA on/off decision, everything else inherited — see SlaPolicy#inherits_config?) still owns
  # no configuration, so it is still inheriting.
  def sla_inherited_policy_source(project)
    return nil if params[:clone_from].present?

    source_project, source_policy = SlaPolicy.config_source_for(project)
    return nil if source_project.nil? || source_project == project

    [source_project, source_policy]
  end

  # Tri-state SLA on/off, shown in the General section while the configuration is inherited:
  # :inherit / :enabled / :disabled for this project, plus whether SLA actually ends up on — so
  # "Inherit" can say WHICH state it inherits.
  def sla_enablement_state(project)
    SlaPolicy.enablement_for(project)
  end

  # What "Inherit" resolves to right now, i.e. the nearest ANCESTOR's decision — computed by
  # asking the parent, so a lightweight row on this project doesn't answer its own question.
  def sla_inherited_enablement_on?(project)
    SlaPolicy.effective_for(project.parent).present?
  end

  # Every section the user may see. Inheritance no longer removes any of them: a subproject renders
  # the same sidebar and the same editable sections as the project it inherits from, pre-filled with
  # the inherited configuration, so changing anything is a normal edit rather than a mode switch.
  def sla_visible_sections(project)
    SECTIONS.select { |section| User.current.allowed_to?(section[:permission], project) }
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

  # --- Locking the configuration sections while SLA tracking is off ---------------------------
  # These four sections only describe how an ACTIVE policy behaves; with tracking off, nothing they
  # hold is ever evaluated, so leaving them editable invites someone to spend an afternoon
  # configuring a policy that does nothing. They stay VISIBLE and readable — only their controls
  # are disabled (see sla_policies/_lock.html.erb). General is deliberately never lockable: it is
  # where tracking gets switched back on, so locking it would be a one-way door.
  LOCKABLE_SECTIONS = %w[targets measurement notifications].freeze

  def sla_lockable_section?(key)
    LOCKABLE_SECTIONS.include?(key)
  end

  # Whether those sections are locked right now, memoised per request.
  def sla_tracking_off?(project)
    return @sla_tracking_off if defined?(@sla_tracking_off)

    @sla_tracking_off = !sla_tracking_on?(project)
  end

  # Read from the SAME value the General section's own control DISPLAYS, not from
  # SlaPolicy.effective_for: the lock must never contradict the switch the user is looking at. The
  # two differ in real cases — a project with no row at all shows the switch off (the column's DB
  # default) while effective_for is also nil, but a clone prefill or a failed validation puts an
  # unsaved policy on screen that no resolver walking the database would ever return.
  def sla_tracking_on?(project)
    # An inheriting project shows the TRI-STATE radios instead of the switch, so "on" there means
    # resolving :inherit against the ancestor's decision — the same thing those radios spell out.
    if sla_inherited_policy_source(project).present?
      state = sla_enablement_state(project)
      state == :inherit ? sla_inherited_enablement_on?(project) : state == :enabled
    else
      sla_policy_for_form(project).enabled?
    end
  end
  private :sla_tracking_on?

  # Is the General section on offer to this user? The locked banner links there, and a
  # notifications-only manager can't go.
  def sla_general_section_visible?(project)
    sla_visible_sections(project).any? { |section| section[:key] == 'general' }
  end

  # Feather-style 24×24 outline icons for the sidebar, keyed by section. Static developer-authored
  # markup (no user data), hence html_safe; `currentColor` lets the nav's active/inactive text
  # colour drive the icon colour with no extra classes.
  SECTION_ICON_PATHS = {
    'general' => '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.6a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
    'measurement' => '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
    'targets' => '<circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2"/>',
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

  # Padlock: on a locked sidebar entry (in place of that row's chevron) and leading the banner that
  # explains the lock, so the two read as the same state rather than two unrelated warnings.
  def sla_lock_icon(size_classes = 'tw-w-4 tw-h-4 tw-shrink-0')
    sla_inline_icon('<rect x="3" y="11" width="18" height="11" rx="2"/>' \
                    '<path d="M7 11V7a5 5 0 0 1 10 0v4"/>', size_classes)
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

  # The policy shown in the form, in precedence order:
  #
  #   1. a controller-provided one (clone prefill / validation failure);
  #   2. this project's own SELF-DEFINING row;
  #   3. an in-memory copy of the configuration it INHERITS — so a subproject opens the same
  #      populated form as its parent instead of a read-only summary, and every field it shows is
  #      the value actually governing its tickets today. Nothing is saved until the user presses a
  #      section's Save, at which point the whole inherited configuration is written as this
  #      project's own (SlaPoliciesController#copy_configuration_from!);
  #   4. a fresh record whose DB defaults give a sensible blank form (no policy anywhere in the tree).
  #
  # A LIGHTWEIGHT row (SlaPolicy#inherits_config?) takes case 3 with its OWN `enabled` kept: its
  # configuration is the ancestor's, but the on/off decision is not.
  def sla_policy_for_form(project)
    @sla_policy ||= sla_own_or_inherited_policy(project)
  end

  def sla_own_or_inherited_policy(project)
    own = SlaPolicy.find_by(project_id: project.id)
    return own if own && !own.inherits_config?

    _source_project, source_policy = SlaPolicy.config_source_for(project)
    Sla::PolicyPrefill.call(project: project, source: source_policy, enabled: own&.enabled) ||
      SlaPolicy.new(project_id: project.id)
  end
  private :sla_own_or_inherited_policy

  # --- Step 6.2a: the Stale threshold's "if you leave this empty" answer ----------------------
  #
  # What would apply to +project+ if it set no value of its own: [days, ancestor_project], or
  # [nil, nil] when nothing would. Asks the PARENT, never the project itself — the point is to
  # describe what the empty field falls back to, and a project's own value is precisely what it
  # would stop using.
  def sla_inherited_stale_threshold(project)
    parent = project&.parent
    days   = SlaPolicy.stale_threshold_days_for(parent)
    return [nil, nil] unless days

    source, _policy = SlaPolicy.stale_threshold_source_for(parent)
    [days, source]
  end

  # Greyed hint inside the empty input: the number that applies if the field is left blank.
  def sla_stale_threshold_placeholder(inherited)
    days, _source = inherited
    days ? l(:label_sla_stale_threshold_placeholder_inherited, days: days)
         : l(:label_sla_stale_threshold_placeholder_unset)
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

  # The trackers whose target tables are displayed — one table each, all saved by the single SLA
  # Targets submit. Explicit request params win (the picker posts `definitions[tracker_ids][]`, and
  # the AJAX re-render of a newly added table posts a single `tracker_id`); otherwise the set is
  # rebuilt from what was saved, and failing everything the project's first tracker so the section
  # is never empty.
  #
  # Selection is only about WHICH trackers are on screen and therefore saved; deselecting one hides
  # it and leaves its stored targets alone (see SlaPoliciesController#replace_tracker_definitions!).
  # Clearing a tracker's targets is done by setting its rows to "not tracked", not by hiding it.
  def sla_selected_trackers(project, policy)
    trackers = project.trackers.sorted.to_a
    requested = sla_requested_tracker_ids
    return trackers.select { |tracker| requested.include?(tracker.id) } if requested.any?

    saved_ids = policy.selected_tracker_ids_or_nil
    # Once the picker has been saved it is authoritative, including an intentionally empty list.
    # Definitions for removed trackers stay stored so re-adding a tracker restores its targets,
    # but they must neither reappear on reload nor remain active in PolicyContext.
    return trackers.select { |tracker| saved_ids.include?(tracker.id) } unless saved_ids.nil?

    trackers.select { |tracker| policy.sla_definitions.map(&:tracker_id).include?(tracker.id) }
  end

  # Tracker ids named by THIS request: the picker's own array, or the single `tracker_id` the AJAX
  # per-table re-render sends. `definitions[tracker_ids][]` is the picker's real parameter name —
  # this used to read a top-level `params[:tracker_ids]` that nothing has ever posted.
  def sla_requested_tracker_ids
    raw = params.dig(:definitions, :tracker_ids).presence || params[:tracker_id].presence
    Array(raw).map(&:to_i)
  end
  private :sla_requested_tracker_ids

  SLA_BEST_EFFORT_VALUE = 'best_effort'

  def sla_direct_duration_parts(seconds, unit = nil)
    return ['', 'hours'] unless seconds.present?
    return Sla::DirectDuration.parts(seconds) unless Sla::DirectDuration::UNITS.key?(unit.to_s)

    amount = BigDecimal(seconds.to_s) / Sla::DirectDuration::UNITS.fetch(unit.to_s)
    [amount.to_s('F').sub(/\.0+\z/, ''), unit.to_s]
  end

  def sla_direct_duration_label(seconds, best_effort, unit = nil)
    Sla::DirectDuration.label(seconds: seconds, best_effort: best_effort, unit: unit)
  end

  # Source candidates for "Clone from another project": projects the user could edit the
  # policy of, that actually have one — minus the current project.
  def sla_clone_source_projects(project)
    Project.active.allowed_to(:edit_sla_policy)
           .where(id: SlaPolicy.select(:project_id))
           .where.not(id: project.id)
           .sorted
  end

  # The project this policy was last cloned from (migration 009), or nil. It preselects the Clone
  # card's dropdown, which otherwise reopened on "— Select a project —" and left the provenance of a
  # whole configuration knowable only to whoever ran the clone, at the moment they ran it.
  #
  # Resolved against +sources+ — the list actually in the dropdown — rather than looked up directly,
  # because this is deliberately a plain id and not a foreign key: the source project may since have
  # been archived, had its policy removed, or become one this user may not edit. In any of those
  # cases it is not an option on this page, and preselecting an id that has no <option> would render
  # as no selection anyway. Returning nil says so honestly.
  def sla_cloned_from_project(policy, sources)
    id = policy.cloned_from_project_id
    id.present? ? sources.detect { |source| source.id == id } : nil
  end

  # Notification settings shown in the tab's second section (4.6).
  def sla_notification_setting_for_form(project)
    @sla_notification_setting ||= SlaNotificationSetting.find_by(project_id: project.id) ||
                                  SlaNotificationSetting.new(project_id: project.id)
  end

  def sla_notification_fallbacks(project)
    return {} if sla_tracking_off?(project)

    resolver = Sla::NotificationSettingsResolver.new(project)
    %i[google_chat at_risk_email stale_email].index_with do |channel|
      resolution = resolver.resolve(channel)
      resolution if resolution.inherited?
    end.compact
  end

  def sla_notification_fallback_text(resolution)
    if resolution.source == :parent
      l(:text_sla_notification_parent_fallback, project: resolution.source_project.name)
    else
      l(:text_sla_notification_admin_fallback)
    end
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

  # Neutral outlined button (the Clone section's "Load"). Was also "Revert to inherited policy" on
  # the reasoning that the primary colour should stay reserved for the one save action per section;
  # that call was overruled — Revert is a deliberate, consequential action of its own and was being
  # missed entirely as a grey outline, so it now uses sla_primary_button_classes above.
  def sla_secondary_button_classes
    'tw-inline-flex tw-items-center tw-gap-2 tw-text-gray-900 tw-bg-white tw-border ' \
      'tw-border-solid tw-border-gray-300 hover:tw-bg-gray-100 ' \
      'tw-font-medium tw-rounded-lg tw-text-sm tw-px-4 tw-py-2.5 tw-cursor-pointer'
  end
end
