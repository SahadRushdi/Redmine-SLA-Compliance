# Plugin routes. Project-scoped dashboard (Phase 6); policy + notification settings (Phase 4);
# admin-managed lookups (target options, business calendars); the access allow-list user search
# (Phase 5).
Rails.application.routes.draw do
  resources :projects, only: [] do
    resources :sla_dashboard, only: [:index], controller: 'sla_dashboard'
    resource :sla_policy, only: [:edit, :update, :destroy], controller: 'sla_policies'
    resource :sla_notification_setting, only: [:update], controller: 'sla_notification_settings'
  end

  resources :sla_target_options, except: [:show]
  resources :sla_business_calendars, except: [:show]

  # Typeahead for the two user allow-list pickers on the plugin settings form.
  get 'sla_access/users', to: 'sla_access#users', as: :sla_access_users
end
