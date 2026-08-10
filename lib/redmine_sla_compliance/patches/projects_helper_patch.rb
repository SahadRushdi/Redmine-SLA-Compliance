# frozen_string_literal: true

module RedmineSlaCompliance
  module Patches
    # Adds the "SLA Policy" tab to Project Settings.
    # Appended AFTER super: core's project_settings_tabs filters by a single tab[:action]
    # permission, but this tab hosts two independently-gated sections (policy form under
    # :edit_sla_policy, notifications under :manage_sla_notifications), so the patch does its
    # own gating — show the tab when the user holds either permission and the module is on.
    # `allowed_to?` also answers for the Step 5.1 SLA access roles (see UserPatch), so a member
    # holding one of the configured roles gets the tab without that role ticking the permission.
    module ProjectsHelperPatch
      def project_settings_tabs
        tabs = super
        if @project&.module_enabled?(:sla_compliance)
          action = %i[edit_sla_policy manage_sla_notifications].find do |permission|
            User.current.allowed_to?(permission, @project)
          end
          if action
            tabs << { name: 'sla_policy', action: action,
                      partial: 'projects/settings/sla_policy', label: :label_sla_policy }
          end
        end
        tabs
      end
    end
  end
end
