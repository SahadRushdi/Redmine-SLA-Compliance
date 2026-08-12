# Plugin routes. Project-scoped dashboard plus policy and notification settings.
Rails.application.routes.draw do
  # Step 6.1 — top-level (cross-project) dashboard, alongside the project-nested one below.
  get 'sla_dashboard', to: 'sla_dashboard#cross_project', as: :sla_dashboard_cross_project

  resources :projects, only: [] do
    resources :sla_dashboard, only: [:index], controller: 'sla_dashboard'
    resource :sla_policy, only: [:edit, :update, :destroy], controller: 'sla_policies' do
      patch :target, action: :update_target
      patch :add_tracker
      delete :remove_tracker
      patch :clone_tracker, action: :clone_tracker
      post :recalculate
      get :recalculation_status
    end
    resource :sla_notification_setting, only: [:update], controller: 'sla_notification_settings'
  end

  # Administration → SLA Compliance. A singular resource of its own rather than Redmine's
  # settings/plugin/:id page — see SlaSettingsController for why it had to move.
  get 'sla_settings', to: 'sla_settings#show', as: :sla_settings
  patch 'sla_settings', to: 'sla_settings#update'
  patch 'sla_settings/notifications', to: 'sla_notification_settings#update_global',
                                      as: :sla_global_notification_setting
end
