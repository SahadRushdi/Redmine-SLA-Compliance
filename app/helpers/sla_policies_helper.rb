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

  # <option> list for one target dropdown: a leading "not tracked" blank, then the admin
  # lookup. If the saved value no longer matches any option (the admin edited the lookup),
  # inject it so it isn't silently dropped on the next save.
  def sla_target_select_options(target_type, current_seconds)
    options = sla_target_options_by_type.fetch(target_type.to_s, [])
                                        .map { |o| [o.label, o.seconds] }
    if current_seconds.present? && options.none? { |_, seconds| seconds == current_seconds }
      options.unshift([l(:label_sla_target_current_value,
                         value: format_sla_duration(current_seconds)), current_seconds])
    end
    options.unshift([l(:label_sla_target_skipped), ''])
    options_for_select(options, current_seconds || '')
  end

  def sla_target_options_by_type
    @sla_target_options_by_type ||=
      SlaTargetOption.order(:position, :seconds).group_by(&:target_type)
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
