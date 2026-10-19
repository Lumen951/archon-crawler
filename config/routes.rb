Rails.application.routes.draw do
  # Authentication routes
  resource :session, only: [:new, :create, :destroy] do
    post :magic_link
    post :dev_login if Rails.env.development? || Rails.env.test?
  end
  get '/magic_link/:token', to: 'sessions#magic_link_login', as: :magic_link

  # Feishu message-card callback (public, verified by signature)
  post '/feishu/card_callback', to: 'feishu_callbacks#card', as: :feishu_callback
  get  '/feishu/card_callback', to: 'feishu_callbacks#card'

  root "dashboard#index"

  # Authenticated user routes (no admin required)
  get 'dashboard', to: 'dashboard#index', as: :dashboard

  resources :articles, only: [:index, :show] do
    member do
      post :download_content
    end
  end

  resources :papers, only: [:index, :show] do
    collection do
      get :import
      post :create_import
    end
  end
  resources :paper_import_tasks, only: [:show] do
    member do
      get :poll
    end
  end

  resources :accounts, only: [:index, :show, :update, :destroy] do
    collection do
      post :bulk_tag
      post :bulk_untag
      post :bulk_enable
      post :bulk_disable
      post :bulk_enable_weekly_research
      post :bulk_disable_weekly_research
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
      # Website import routes
      get  "import/website", to: "accounts#import_website_page", as: :import_website_page
      post :import_website
      # Event research import routes
      get  "import/event", to: "accounts#import_event_page", as: :import_event_page
      post "import/event", to: "accounts#import_event", as: :import_event
    end
    member do
      post :crawl
      post :toggle_status
      post :resolve_weread_mp_id
      post :rediscover
      patch :update_crawl_rule
      post :generate_crawl_rule
      get :edit_event
      patch :update_event
    end
  end

  # 活动研究控制台：与抓取管线独立，show 页就是调研的入口与结果中心
  resources :event_accounts, only: [ :show ] do
    member do
      post :start_research
      post :fail_run
      get :logs
      get :poll
      get :download
    end
  end

  resources :event_research_tasks, only: [ :index, :show, :create, :destroy ] do
    member do
      post :pause
      post :resume
      post :fail
      get :logs
      get :poll
    end
  end

  # 每个活动研究任务的一份聚合报告；仅定时任务自动推送
  resources :event_weekly_digests, only: [ :index, :show ] do
    member do
      post :resend
      post :regenerate
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

  resources :wechat_url_import_tasks, only: [:index, :show, :destroy] do
    member do
      get :poll
    end
  end

  resources :wechat_content_download_tasks, only: [:index, :show, :destroy] do
    collection do
      post :run
    end
    member do
      post :retry
      post :fail
      get :logs
      get :poll
    end
  end

  resources :monitor_changes, only: [:index, :show]

  resources :monitor_pages, only: [:show]
  resources :monitor_page_versions, only: [:show]

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
      # 扫码登录（provider=weread / wechat_mp，见 QrLogin）
      post :qr_login_request
      get  :qr_login_status
      # 远程浏览器登录（provider=wechat_mp / rednote_web / weread_native，见 BrowserLogin）
      post :browser_login_start
      get  :browser_login_frame
      post :browser_login_interact
      post :browser_login_stop
      # MP Native
      post :wechat_mp_logout
      post :validate_mp_native_key
      # 小红书网页版 Cookie 会话（远程浏览器登录写入）
      post :rednote_web_logout
      # WeRead
      post :weread_logout
      post :validate_weread_key
      # WeRead Native (直连扫码登录)
      post :weread_native_logout
      post :validate_weread_native_key
      # WeRead account management
      post :weread_enable_account
      post :weread_disable_account
      post :weread_remove_account
      # Feishu push
      post :test_feishu
    end

    resource :analytics, only: [:show] do
      post :bulk_disable_dormant
    end

    resources :mcp_tool_calls, only: [:index, :show]
    resources :oauth_applications, only: [:index, :destroy]
  end

  get "/rss", to: "rss#index", as: :all_accounts_rss, defaults: { format: 'rss' }
  get "/rss/accounts", to: "rss#accounts", as: :accounts_list_rss, defaults: { format: 'rss' }
  get "/rss/accounts/active", to: "rss#active_accounts", as: :active_accounts_list_rss, defaults: { format: 'rss' }
  get "/rss/tag/:tag_id", to: "rss#by_tag", as: :tag_rss, defaults: { format: 'rss' }
  get "/rss/user/:token", to: "rss#by_user", as: :user_rss, defaults: { format: 'rss' }
  get "/rss/monitor/changes/important", to: "rss#monitor_changes", as: :important_monitor_changes_rss, defaults: { format: 'rss', important: '1' }
  get "/rss/monitor/changes", to: "rss#monitor_changes", as: :monitor_changes_rss, defaults: { format: 'rss' }
  get "/rss/monitor/accounts/:id/changes", to: "rss#monitor_website_changes", as: :monitor_website_changes_rss, defaults: { format: 'rss' }
  get "/rss/monitor/pages/:id/changes", to: "rss#monitor_page_changes", as: :monitor_page_changes_rss, defaults: { format: 'rss' }
  get "/rss/monitor/pages", to: "rss#monitor_pages", as: :monitor_pages_rss, defaults: { format: 'rss' }
  get "/rss/monitor/accounts/:id/pages", to: "rss#monitor_website_pages", as: :monitor_website_pages_rss, defaults: { format: 'rss' }
  get "/rss/:fakeid", to: "rss#show", as: :account_rss, defaults: { format: 'rss' }

  # API routes
  namespace :api do
    namespace :v1 do
      resources :groups, only: [:index, :show, :create, :update, :destroy]
      resources :articles, only: [:index]
      resources :accounts, only: [:index, :show, :update] do
        collection do
          post :bulk_update
          get :lookup
        end
      end
      resources :tags, only: [:index, :show, :create]
      resources :event_research_runs, only: [:index, :show]
    end
  end

  # MCP endpoint
  post   "mcp/endpoint", to: "mcp#endpoint"
  get    "mcp/endpoint", to: "mcp#endpoint"
  delete "mcp/endpoint", to: "mcp#endpoint"

  # MCP guide page
  get "mcp", to: "mcp_guide#show", as: :mcp_guide
  post "mcp/tokens", to: "mcp_guide#create_token", as: :create_token_mcp_guide
  delete "mcp/tokens/:id", to: "mcp_guide#revoke_token", as: :revoke_token_mcp_guide

  # API docs
  get "api-docs", to: "api_docs#show", as: :api_docs
  get "api-docs/openapi.json", to: "api_docs#openapi", as: :api_docs_openapi

  # OAuth 2.1 authorization server. Gives MCP clients (Claude Code, Codex, ...)
  # a flow they can discover and drive on their own, instead of the user pasting
  # a long-lived API key. Provides /oauth/authorize, /oauth/token, /oauth/revoke
  # and /oauth/introspect.
  use_doorkeeper do
    controllers authorizations: "oauth/authorizations", tokens: "oauth/tokens"
    skip_controllers :applications, :authorized_applications
  end

  namespace :oauth do
    # RFC 7591 Dynamic Client Registration. Deprecated by the 2026-07-28 spec in
    # favour of Client ID Metadata Documents, but it is still what Claude Code
    # and Codex attempt first, so it stays the supported path.
    post "register", to: "registrations#create"

    # RFC 8628 device flow, kept for headless clients that cannot open a browser.
    post "device", to: "device#create"
    get  "device/authorize", to: "device#show"
    post "device/authorize", to: "device#authorize"
  end

  # OAuth discovery documents (RFC 9728 protected resource, RFC 8414 authorization
  # server). Each is served both bare and with the resource path appended, because
  # clients differ in which form they probe.
  get ".well-known/oauth-protected-resource", to: "well_known#protected_resource"
  get ".well-known/oauth-protected-resource/*resource_path", to: "well_known#protected_resource"
  get ".well-known/oauth-authorization-server", to: "well_known#authorization_server"
  get ".well-known/oauth-authorization-server/*resource_path", to: "well_known#authorization_server"

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  mount MissionControl::Jobs::Engine, at: "/admin/jobs"
end
