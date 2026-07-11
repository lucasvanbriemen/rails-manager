Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  root to: "dashboard#index"

  resources :apps do
    member do
      post :deploy        # git pull / unpack upload, then build + restart
      get  :logs          # tail production.log + apache error_log
    end
    resources :deployments, only: [ :show ]
  end
end
