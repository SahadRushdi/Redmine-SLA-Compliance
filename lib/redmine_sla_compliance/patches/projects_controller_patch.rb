# frozen_string_literal: true

module RedmineSlaCompliance
  module Patches
    # Pre-ticks the SLA Compliance module on the New Project form when the project is being created
    # UNDER a parent that already has it.
    #
    # The SLA policy itself is inherited (Global Rule 5), but Redmine does not inherit module
    # selection — a new subproject takes Setting.default_projects_modules regardless of its parent.
    # That left the last manual step in an otherwise automatic chain: the child inherited the whole
    # policy and was still invisible to the dashboard and the sweep until someone ticked a box.
    #
    # Deliberately only a DEFAULT, and deliberately only in #new: it changes what the form arrives
    # pre-filled with, nothing else. #create is untouched, so the checkbox the user actually
    # submitted always wins and unticking it sticks — "on by default, off if you say so". Enabling
    # it in an after_create callback instead would have overruled that choice with no way to refuse.
    module ProjectsControllerPatch
      def new
        super
        default_sla_module_from_parent
      end

      private

      def default_sla_module_from_parent
        return unless @project&.new_record?
        # Mirrors the same guard the module checkboxes are rendered behind (projects/_form), so we
        # never pre-tick a control the user was never offered and cannot turn off.
        return unless @project.safe_attribute?('enabled_module_names')

        parent = requested_parent_project
        return unless parent&.module_enabled?(:sla_compliance)

        @project.enable_module!(:sla_compliance)
      end

      # Where the form gets its parent from — the same two params, in the same order, as core's
      # ProjectsHelper#parent_project_select_tag. `project[parent_id]` is the re-rendered form
      # after a validation failure; `parent_id` is the "New subproject" link.
      def requested_parent_project
        parent_id = params.dig(:project, :parent_id).presence || params[:parent_id].presence
        return nil if parent_id.blank?

        Project.find_by(id: parent_id)
      end
    end
  end
end
