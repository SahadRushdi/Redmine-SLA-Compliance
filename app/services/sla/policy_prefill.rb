# frozen_string_literal: true

module Sla
  # Builds an UNSAVED SlaPolicy for +project+ mirroring +source+ — the in-memory copy that
  # pre-populates the SLA Policy settings form. Two callers share it, which is the point of
  # extracting it: SlaPoliciesController#edit (Step 4.7's "Clone from another project") and
  # SlaPoliciesHelper#sla_policy_for_form, which renders the same editable form for a project whose
  # configuration is inherited from an ancestor.
  #
  # Only references that are valid in THIS project survive: status mappings keep statuses the
  # project actually uses, definitions keep trackers it has enabled. A copied reference to a status
  # or tracker the project cannot use would be invisible on the form yet still saved.
  #
  # Never persists and never assigns an id — the record is a form-population vehicle only. Whether
  # it becomes a real row is decided by the user pressing Save (SlaPoliciesController#update).
  class PolicyPrefill
    def self.call(project:, source:, enabled: nil)
      new(project: project, source: source, enabled: enabled).call
    end

    # +enabled+ overrides the source's own flag. Used for a project holding a LIGHTWEIGHT row
    # (SlaPolicy#inherits_config?): its configuration comes from the ancestor, but the on/off
    # decision is its own and must not be overwritten by the ancestor's.
    def initialize(project:, source:, enabled: nil)
      @project = project
      @source  = source
      @enabled = enabled
    end

    def call
      return nil if @source.nil?

      policy = SlaPolicy.new(
        project_id: @project.id,
        enabled: @enabled.nil? ? @source.enabled : @enabled,
        coverage_hours: @source.coverage_hours,
        business_calendar_id: @source.business_calendar_id,
        first_response_rule: @source.first_response_rule,
        at_risk_threshold: @source.at_risk_threshold,
        stale_threshold_days: @source.stale_threshold_days,
        pause_enabled: @source.pause_enabled
      )
      build_status_mappings(policy)
      build_definitions(policy)
      policy
    end

    private

    def build_status_mappings(policy)
      status_ids = @project.rolled_up_statuses.map(&:id)
      @source.sla_status_mappings.each do |mapping|
        next unless status_ids.include?(mapping.status_id)

        policy.sla_status_mappings.build(role: mapping.role, status_id: mapping.status_id)
      end
    end

    def build_definitions(policy)
      tracker_ids = @project.trackers.ids
      unclassified_priority_id = Sla::PluginSettings.unclassified_priority_id
      @source.sla_definitions.each do |definition|
        next unless tracker_ids.include?(definition.tracker_id)
        # The unclassified priority can hold no target and gets no form row, so a stale one on the
        # source would select its tracker's table while showing nothing in it.
        next if definition.priority_id == unclassified_priority_id

        policy.sla_definitions.build(definition.attributes.slice(*SlaDefinition::COPY_ATTRIBUTES))
      end
    end
  end
end
