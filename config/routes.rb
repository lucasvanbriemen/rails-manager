Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  root to: "dashboard#index"

  resources :apps do
    member do
      post :deploy        # git pull / unpack upload, then build + restart
      get  :logs          # browse/tail the app's log files
    end
    resources :deployments, only: [ :show ]
    resources :exception_groups, only: [ :index, :show ], path: "exceptions" do
      member do
        post :resolve
        post :reopen
      end
    end
    resources :console_sessions, only: [ :create, :show, :destroy ] do
      post :input, on: :member
    end
  end

  # Managed apps POST uncaught exceptions here (per-app ingest token).
  namespace :api do
    resources :exceptions, only: [ :create ]

    # Git push webhooks. Authenticated by HMAC over the raw body, not by the
    # token in the path — see Api::WebhooksController.
    post "webhooks/:token", to: "webhooks#create", as: :webhook
  end
end
