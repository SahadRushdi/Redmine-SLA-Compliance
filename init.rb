require 'redmine'

Redmine::Plugin.register :redmine_sla_compliance do
  name 'Redmine SLA Compliance Plugin'
  author 'Sahad Rushdi'
  description 'Per-project SLA policies and automatic SLA-compliance measurement for incident ' \
              'tickets, with a filterable dashboard, Google Chat + email notifications, and a ' \
              'time-driven at-risk/stale sweep.'
  version '0.1.0'
  url 'https://github.com/SahadRushdi/redmine-plugins'

  requires_redmine version_or_higher: '5.1.0'

  # Global plugin settings (expanded in Phase 5). Declared now so the admin-menu stub renders
  # a real settings page instead of erroring.
  settings default: {}, partial: 'sla_compliance/settings'

  # --- Step 0.2: project module + named permissions ---------------------------------------
  # Permission names are STABLE — later steps reference them verbatim. Do not rename.
  project_module :sla_compliance do
    # View the SLA compliance dashboard (read-only; visible in Reports-style contexts).
    permission :view_sla_dashboard, { sla_dashboard: [:index] }, read: true

    # Create/edit the project's SLA policy (Project Settings → SLA Policy tab, Phase 4).
    permission :edit_sla_policy, { sla_policies: [:edit, :update] }

    # Manage per-project notification settings (Google Chat webhook, at-risk/stale email).
    permission :manage_sla_notifications, { sla_notification_settings: [:edit, :update] }
  end

  # --- Menu stubs -------------------------------------------------------------------------
  # Project-level entry to the dashboard, gated by the view permission and the module being
  # enabled on the project (allowed_to? returns false when the module is disabled).
  menu :project_menu, :sla_compliance,
       { controller: 'sla_dashboard', action: 'index' },
       caption: :label_sla_compliance,
       after: :activity,
       param: :project_id,
       if: Proc.new { |p| User.current.allowed_to?(:view_sla_dashboard, p) }

  # Global plugin settings screen stub (fleshed out in Phase 5 — access control / lookups).
  menu :admin_menu, :sla_compliance_settings,
       { controller: 'settings', action: 'plugin', id: 'redmine_sla_compliance' },
       caption: :label_sla_compliance_settings,
       html: { class: 'icon', style: 'background-image: url(/images/time.png)' }
end
