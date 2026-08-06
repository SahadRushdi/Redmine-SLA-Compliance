# Plugin routes. Project-scoped dashboard (Phase 6); policy + notification settings (Phase 4);
# admin-managed lookups (target options, business calendars).
Rails.application.routes.draw do
  # Step 6.1 — top-level (cross-project) dashboard, alongside the project-nested one below.
  get 'sla_dashboard', to: 'sla_dashboard#cross_project', as: :sla_dashboard_cross_project

  resources :projects, only: [] do
    resources :sla_dashboard, only: [:index], controller: 'sla_dashboard'
    resource :sla_policy, only: [:edit, :update, :destroy], controller: 'sla_policies'
    resource :sla_notification_setting, only: [:update], controller: 'sla_notification_settings'
  end

  # Administration → SLA Compliance. A singular resource of its own rather than Redmine's
  # settings/plugin/:id page — see SlaSettingsController for why it had to move.
  get 'sla_settings', to: 'sla_settings#show', as: :sla_settings
  patch 'sla_settings', to: 'sla_settings#update'

  resources :sla_target_options, except: [:show]
  resources :sla_business_calendars, except: [:show]
end
