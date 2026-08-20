# frozen_string_literal: true

module Sla
  # Reads the plugin's GLOBAL settings (Administration → SLA Compliance), which are
  # instance-wide rather than per-project. Backed by Redmine's own plugin-settings
  # mechanism (`Setting.plugin_redmine_sla_compliance`,
  # declared in init.rb), so no extra table or migration is needed for these.
  #
  # Centralised here (rather than reading `Setting.plugin_redmine_sla_compliance` inline) so the
  # parsing/defaulting logic exists in exactly one place,
  # per the CLAUDE.md "reuse code, don't duplicate" convention.
  class PluginSettings
    class << self
      # --- Step 5.1: role-based SLA access ------------------------------------------------------
      #
      # Which Redmine ROLES carry SLA access. A user who holds one of these roles on a project
      # they can already open sees that project's SLA dashboard and its SLA Policy settings —
      # whatever the role's own permission checkboxes say, so the three SLA permissions do not
      # have to be ticked on every role one by one. Sla::AccessControl turns this list into an
      # answer.
      #
      # Stored as role IDs per Global Rule 2 (references, never labels) inside the same
      # plugin-settings hash as everything above — no table, no migration.
      #
      # Read fresh on every call, like the settings above: `Setting` invalidates its cache when an
      # admin saves the form, which is what makes a granted (or revoked) role take effect on the
      # very next request with no restart.
      #
      # HISTORY: this replaced two per-USER allow-lists ('sla_viewer_user_ids' /
      # 'sla_manager_user_ids') on 2026-08-06, along with the viewer/manager split they encoded.
      # Nothing reads those keys any more, and SlaSettingsController#update drops them from the
      # stored hash on the next save.
      def access_role_ids
        # The settings form posts a blank sentinel entry (so the `[]` param still arrives when
        # every chip has been removed) and SlaSettingsController#update stores what it is given
        # verbatim — so the cleanup has to happen on read. Tolerates a nil or non-array value,
        # which is what a hand-edited or pre-2026-08-06 settings hash looks like.
        Array(settings['sla_access_role_ids']).reject(&:blank?).map(&:to_i).uniq
      end

      private

      def settings
        Setting.plugin_redmine_sla_compliance || {}
      end
    end
  end
end
