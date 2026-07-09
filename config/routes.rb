# Plugin routes. Project-scoped dashboard (Phase 6); more routes added per phase.
Rails.application.routes.draw do
  resources :projects, only: [] do
    resources :sla_dashboard, only: [:index], controller: 'sla_dashboard'
  end
end
