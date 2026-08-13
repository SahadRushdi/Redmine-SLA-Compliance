require 'redmine'

Redmine::Plugin.register :redmine_sla_compliance do
  name 'Redmine SLA Compliance Plugin'
  author 'Sahad Rushdi'
  description 'Per-project SLA policies and automatic SLA-compliance measurement for incident ' \
              'tickets, with a live filterable dashboard and Google Chat + email notifications.'
  version '0.1.0'
  url 'https://github.com/SahadRushdi/redmine-plugins'

  requires_redmine version_or_higher: '5.1.0'

  # Global plugin settings, stored as one serialized hash under
  # `Setting.plugin_redmine_sla_compliance` and read through Sla::PluginSettings.
  #
  # DELIBERATELY NO `:partial`. Redmine::Plugin#configurable? is `settings[:partial].present?`, and
  # it is what puts the "Configure" link on the Plugins list and lets SettingsController#plugin
  # render. This plugin's settings have their own page (SlaSettingsController, reached from the
  # "SLA Compliance" entry in the Administration sidebar), so a second way in would be a duplicate
  # that could never highlight the right sidebar entry — see that controller for the full reason.
  # Setting.define_plugin_setting only requires `settings` to be present, so the stored hash and
  # this default are unaffected by the omission.
  settings default: {}

  # --- Step 0.2: project module + named permissions ---------------------------------------
  # Permission names are STABLE — later steps reference them verbatim. Do not rename.
  project_module :sla_compliance do
    # View the SLA compliance dashboard (read-only; visible in Reports-style contexts).
    permission :view_sla_dashboard, { sla_dashboard: [:index] }, read: true

    # Create/edit the project's SLA policy (Project Settings → SLA Policy tab, Phase 4).
    # :destroy is B3's "Revert to inherited policy" action.
    #
    # `projects: [:settings]` is what makes the tab actually REACHABLE: the page hosting it is
    # ProjectsController#settings, which Redmine gates on :edit_project (require_member). Without
    # claiming that action here, a role granted only :edit_sla_policy would be shown no Settings
    # menu link and 403 on the URL — the tab could never be opened. This mirrors how core's own
    # :manage_members / :manage_versions / :manage_categories each claim projects/settings.
    # Holding it grants nothing else: every other tab stays filtered by its own permission.
    permission :edit_sla_policy, { sla_policies: [:edit, :update, :update_tracking, :update_measurement,
                                                  :update_target, :add_tracker,
                                                  :remove_tracker, :clone_tracker,
                                                  :recalculate, :recalculation_status, :destroy],
                                   projects: [:settings] }

    # Manage per-project notification settings (Google Chat webhook, at-risk/stale email).
    permission :manage_sla_notifications, { sla_notification_settings: [:edit, :update],
                                            projects: [:settings] }
  end

  # --- Menu stubs -------------------------------------------------------------------------
  # Project-level entry to the dashboard, gated by the view permission and the module being
  # enabled on the project (allowed_to? returns false when the module is disabled). Step 5.1's
  # user allow-list is answered by allowed_to? itself (see UserPatch), so a listed viewer sees
  # this entry without holding any role on the project.
  menu :project_menu, :sla_compliance,
       { controller: 'sla_dashboard', action: 'index' },
       caption: :label_sla_compliance,
       after: :activity,
       param: :project_id,
       if: Proc.new { |p| User.current.allowed_to?(:view_sla_dashboard, p) }

  # Step 6.1 — top-level (cross-project) entry point. Named distinctly from the :project_menu
  # item above so its dasherized CSS class (.sla-dashboard-all) never collides with the existing
  # project-tab link's (.sla-compliance), and so each is independently testable. For
  # :application_menu items Redmine passes project = nil to this proc and does NOT separately
  # auto-authorize a Hash url the way it does for :project_menu items, so gating lives entirely
  # here — there is no single global :view_sla_dashboard permission to check, only a per-project
  # one, hence the SlaPolicy.enabled_projects_for scan.
  menu :application_menu, :sla_dashboard_all,
       { controller: 'sla_dashboard', action: 'cross_project' },
       caption: :label_sla_dashboard_all,
       if: Proc.new { |_project| User.current.logged? && SlaPolicy.enabled_projects_for(User.current).any? }

  # The admin module's single General entry point.
  menu :admin_menu, :sla_compliance_settings,
       { controller: 'sla_settings', action: 'show' },
       caption: :label_sla_compliance_settings,
       html: { class: 'icon', style: 'background-image: url(/images/time.png)' }
end

# --- Event-driven recompute --------------------------------------------------------
# Wired after full app initialization so Issue and the plugin's autoloaded services are available.
Rails.application.config.after_initialize do
  require_dependency File.expand_path('lib/redmine_sla_compliance/patches/issue_patch', __dir__)
  require_dependency File.expand_path('lib/redmine_sla_compliance/patches/projects_helper_patch', __dir__)
  require_dependency File.expand_path('lib/redmine_sla_compliance/patches/projects_controller_patch', __dir__)
  require_dependency File.expand_path('lib/redmine_sla_compliance/patches/user_patch', __dir__)

  # Step 3.1 — recompute an issue's cached SLA result on every change (idempotent include guard).
  unless Issue.included_modules.include?(RedmineSlaCompliance::Patches::IssuePatch)
    Issue.include(RedmineSlaCompliance::Patches::IssuePatch)
  end

  # Step 5.1 — make Redmine's own permission check honour the SLA user allow-list. Prepended so
  # the patch's allowed_to? runs first and can fall through to core's via super; every SLA gate
  # (project menu, authorize, settings tabs, view partials) asks this one method, so this is the
  # only place the allow-list has to be taught about.
  unless User.included_modules.include?(RedmineSlaCompliance::Patches::UserPatch)
    User.prepend(RedmineSlaCompliance::Patches::UserPatch)
  end

  # Step 4.1 — SLA Policy tab under Project Settings.
  unless ProjectsHelper.include?(RedmineSlaCompliance::Patches::ProjectsHelperPatch)
    ProjectsHelper.prepend(RedmineSlaCompliance::Patches::ProjectsHelperPatch)
  end
  # Step 6A.4 — a new subproject of an SLA-enabled project arrives with the module already
  # ticked, since the policy it inherits is useless while the module is off. Prepended so the
  # patch runs AFTER core's #new has built @project (it calls super first).
  unless ProjectsController.include?(RedmineSlaCompliance::Patches::ProjectsControllerPatch)
    ProjectsController.prepend(RedmineSlaCompliance::Patches::ProjectsControllerPatch)
  end

  # The tab partial renders inside ProjectsController#settings, whose views don't include
  # plugin helpers by default — make the form helpers available there.
  ProjectsController.helper(:sla_policies)
  ProjectsController.helper(:sla_compliance)

end
