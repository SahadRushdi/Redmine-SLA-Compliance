# frozen_string_literal: true

# Data source for the SLA Policy settings tab. The tab partial renders inside
# ProjectsController#settings (no plugin controller runs on that GET), so everything the form
# needs is derived here. All lists come live from Redmine configuration — never constants.
module SlaPoliciesHelper
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
end
