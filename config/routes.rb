Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  root to: "dashboard#index"

  # Adopt existing Plesk subdomains that aren't tracked yet.
  post "import", to: "apps#import", as: :import_apps

  resources :apps do
    member do
      post :deploy        # git pull / unpack upload, then build + restart
      post :restart       # touch tmp/restart.txt
      post :migrate_primary # explicit, guarded migration of an external primary DB
      get  :logs          # tail production.log + apache error_log
    end
    resources :deployments, only: [ :show ]
  end
end
