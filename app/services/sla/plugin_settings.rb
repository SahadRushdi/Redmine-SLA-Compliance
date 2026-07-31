# frozen_string_literal: true

module Sla
  # Reads the plugin's GLOBAL settings (Administration → Plugins → SLA Compliance), which are
  # instance-wide rather than per-project — the sweep cadence and the "which priority means
  # unclassified" mapping both fit that shape, unlike everything in Phase 4's per-project policy
  # tab. Backed by Redmine's own plugin-settings mechanism (`Setting.plugin_redmine_sla_compliance`,
  # declared in init.rb), so no extra table or migration is needed for these.
  #
  # Centralised here (rather than reading `Setting.plugin_redmine_sla_compliance` inline in the
  # scheduler and the engine) so the parsing/clamping/defaulting logic exists in exactly one place,
  # per the CLAUDE.md "reuse code, don't duplicate" convention.
  class PluginSettings
    DEFAULT_SWEEP_INTERVAL_MINUTES = 15
    MIN_SWEEP_INTERVAL_MINUTES = 1
    MAX_SWEEP_INTERVAL_MINUTES = 1440 # 24h — a sweep that rarely runs still shouldn't be "never"

    class << self
      # Sweep cadence in minutes (Fixed Decisions: "every 15 minutes, configurable"). Read fresh
      # on every call — Redmine's `Setting` already caches this in-process and invalidates the
      # cache when an admin saves the settings form, so a changed value takes effect without an
      # app restart. Falls back to the plan's 15-minute default and is clamped to a sane range so
      # a stray/blank admin input can't produce a zero or absurd interval.
      def sweep_interval_minutes
        raw = settings['sweep_interval_minutes'].to_i
        return DEFAULT_SWEEP_INTERVAL_MINUTES unless raw.positive?

        raw.clamp(MIN_SWEEP_INTERVAL_MINUTES, MAX_SWEEP_INTERVAL_MINUTES)
      end

      # The IssuePriority ID that represents "None / unclassified" (plan Step 4.4 and the spec
      # PDF's terminology table both call for this priority to always be excluded from SLA
      # evaluation). Priorities are a single global list in Redmine — not scoped per project or
      # tracker — so this is a global setting, stored as an ID per Global Rule 2 (never a label).
      #
      # If the admin hasn't explicitly picked one, auto-detect a priority literally named "None"
      # (case-insensitively) as a zero-config default matching this plugin's reference customer
      # setup (see the spec PDF's priority table) — a convenience default, not a hardcoded rule:
      # an admin can point this at any priority, or clear it if the concept doesn't apply.
      def unclassified_priority_id
        configured = settings['unclassified_priority_id'].presence
        return configured.to_i if configured

        IssuePriority.where('LOWER(name) = ?', 'none').first&.id
      end

      # Step 7.1 — instance-wide Google Chat webhook, used by any project that has not set its own
      # (the plan's "per-project setting, with a global fallback"). Lives here rather than in a
      # column because it is a single instance-wide value, exactly like the two settings above.
      # `SlaNotificationSetting.google_chat_webhook_for` is what applies the fallback; this only
      # reports the configured default.
      def default_google_chat_webhook
        settings['google_chat_webhook'].presence
      end

      # --- Step 5.1: the user access allow-lists ----------------------------------------------
      #
      # Redmine permissions attach to roles only, so there is no native way to grant SLA access to
      # a named person. These two lists fill that gap; Sla::AccessControl turns them into an
      # answer. Stored as user IDs per Global Rule 2 (references, never labels) inside the same
      # plugin-settings hash as everything above — no table, no migration.
      #
      # Read fresh on every call, like the settings above: `Setting` invalidates its cache when an
      # admin saves the form, which is what makes a granted (or revoked) user take effect on their
      # very next request with no restart.

      # Dashboard, read-only.
      def viewer_user_ids
        user_ids_setting('sla_viewer_user_ids')
      end

      # Dashboard plus the SLA Policy tab.
      def manager_user_ids
        user_ids_setting('sla_manager_user_ids')
      end

      def viewer_users
        users_for(viewer_user_ids)
      end

      def manager_users
        users_for(manager_user_ids)
      end

      private

      # The settings form posts a blank sentinel entry (so the `[]` param still arrives when every
      # chip has been removed) and Redmine's settings controller stores what it is given verbatim
      # via `permit!.to_h` — so the cleanup has to happen on read. Tolerates a nil or non-array
      # value, which is what a hand-edited or pre-5.1 settings hash looks like.
      def user_ids_setting(key)
        Array(settings[key]).reject(&:blank?).map(&:to_i).uniq
      end

      # Ordered for display, and silently skips IDs whose user has since been deleted.
      def users_for(ids)
        return User.none if ids.empty?

        User.where(id: ids).sorted
      end

      def settings
        Setting.plugin_redmine_sla_compliance || {}
      end
    end
  end
end
