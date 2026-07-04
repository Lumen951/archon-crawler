Rails.application.routes.draw do
  # Authentication routes
  resource :session, only: [:new, :create, :destroy] do
    post :magic_link
    post :dev_login
  end
  get '/magic_link/:token', to: 'sessions#magic_link_login', as: :magic_link

  root "dashboard#index"

  # Authenticated user routes (no admin required)
  get 'dashboard', to: 'dashboard#index', as: :dashboard

  resources :accounts, only: [:index, :show, :destroy] do
    collection do
      get :import
      get :search_preview
      post :import_json
      post :import_search
      post :import_rednote_json
    end
    member do
      post :crawl
      post :toggle_status
    end
  end

  resources :crawl_tasks, only: [:index, :show] do
    collection do
      post :crawl_all
    end
    member do
      post :pause
      post :resume
      get :logs
      get :articles
    end
  end

  # Profile management (users can edit their own password)
  resource :profile, only: [:edit, :update] do
    patch :update_password
  end

  # Admin-only routes
  namespace :admin do
    resources :users do
      member do
        post :reset_password
      end
      collection do
        get :credentials, to: 'users#show_credentials', as: :credentials
      end
    end
    get 'users/:id/credentials', to: 'users#show_credentials', as: :user_credentials

    resource :settings, only: [:show, :update]
  end

  get "/rss", to: "rss#index", as: :all_accounts_rss, defaults: { format: 'rss' }
  get "/rss/accounts", to: "rss#accounts", as: :accounts_list_rss, defaults: { format: 'rss' }
  get "/rss/accounts/active", to: "rss#active_accounts", as: :active_accounts_list_rss, defaults: { format: 'rss' }
  get "/rss/:fakeid", to: "rss#show", as: :account_rss, defaults: { format: 'rss' }

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  mount MissionControl::Jobs::Engine, at: "/admin/jobs"
end
