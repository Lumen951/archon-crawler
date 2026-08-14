Rails.application.routes.draw do
  # Authentication routes
  resource :session, only: [:new, :create, :destroy] do
    post :magic_link
    post :dev_login
  end
  get '/magic_link/:token', to: 'sessions#magic_link_login', as: :magic_link
  get '/auth/:provider', to: 'sessions#oauth_login', as: :oauth_login
  get '/oauth/:provider/callback', to: 'sessions#oauth_callback', as: :oauth_callback

  root "dashboard#index"

  # Authenticated user routes (no admin required)
  get 'dashboard', to: 'dashboard#index', as: :dashboard

  resources :articles, only: [:show] do
    member do
      post :download_content
    end
  end

  resources :accounts, only: [:index, :show, :update, :destroy] do
    collection do
      post :bulk_tag
      post :bulk_untag
      post :bulk_enable
      post :bulk_disable
      post :bulk_destroy
      post :bulk_crawl
      get  :tag_suggestions
      post :toggle_tag_follow
      get :import
      # WeChat import routes
      get  "import/wechat", to: "accounts#import_wechat_page", as: :import_wechat_page
      get  :import_wechat_search
      post :import_wechat
      post :import_wechat_file
      post :import_wechat_by_url
      # RedNote import routes
      get  "import/rednote", to: "accounts#import_rednote_page", as: :import_rednote_page
      get  :import_rednote_search
      post :import_rednote
      post :import_rednote_file
      post :import_rednote_by_id
      # Twitter import routes
      get  "import/twitter", to: "accounts#import_twitter_page", as: :import_twitter_page
      get  :import_twitter_search
      post :import_twitter
      post :import_twitter_file
    end
    member do
      post :crawl
      post :toggle_status
      post :resolve_weread_mp_id
    end
  end

  resources :crawl_tasks, only: [:index, :show, :destroy] do
    collection do
      post :crawl_due
    end
    member do
      post :pause
      post :resume
      post :fail
      get :logs
      get :articles
      get :poll
    end
  end

  # Profile management (users can edit their own password)
  resource :profile, only: [:edit, :update] do
    patch :update_password
    patch :update_followed_tags
    post :create_api_key
    delete :revoke_api_key
  end

  # Admin-only routes
  namespace :admin do
    resources :users do
      member do
        post :reset_password
        patch :update_followed_tags
      end
      collection do
        get :credentials, to: 'users#show_credentials', as: :credentials
      end
    end
    get 'users/:id/credentials', to: 'users#show_credentials', as: :user_credentials

    resources :tags, only: [:index, :edit, :update, :destroy] do
      collection do
        post :refresh_counts
      end
    end

    resource :settings, only: [:show, :update] do
      post :validate_dajiala_key
      post :validate_rednote_key
      post :validate_twitter_key
      post :validate_tikhub_key
      post :validate_profile_ext_key
      # MP Native QR code login
      post :wechat_mp_request_qrcode
      get  :wechat_mp_qrcode_status
      post :wechat_mp_logout
      post :validate_mp_native_key
      # WeRead QR code login
      post :weread_request_qrcode
      get  :weread_qrcode_status
      post :weread_logout
      post :validate_weread_key
      # WeRead account management
      post :weread_enable_account
      post :weread_disable_account
      post :weread_remove_account
    end

    resource :analytics, only: [:show] do
      post :bulk_disable_dormant
    end
  end

  get "/rss", to: "rss#index", as: :all_accounts_rss, defaults: { format: 'rss' }
  get "/rss/accounts", to: "rss#accounts", as: :accounts_list_rss, defaults: { format: 'rss' }
  get "/rss/accounts/active", to: "rss#active_accounts", as: :active_accounts_list_rss, defaults: { format: 'rss' }
  get "/rss/tag/:tag_id", to: "rss#by_tag", as: :tag_rss, defaults: { format: 'rss' }
  get "/rss/user/:token", to: "rss#by_user", as: :user_rss, defaults: { format: 'rss' }
  get "/rss/:fakeid", to: "rss#show", as: :account_rss, defaults: { format: 'rss' }

  # API routes
  namespace :api do
    namespace :v1 do
      resources :groups, only: [:index, :show, :create, :update, :destroy]
      resources :articles, only: [:index]
      resources :accounts, only: [:index]
    end
  end

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  mount MissionControl::Jobs::Engine, at: "/admin/jobs"
end
