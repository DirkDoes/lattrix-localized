Rails.application.routes.draw do
  get "REVISION.txt", to: ->(_env) { [200, { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" }, [Rails.root.join("REVISION.txt").read]] }

  resource :profile_photo, only: [:update, :destroy]
  get "profile_photos/:id", to: "profile_photos#show", as: :profile_photo_image
  resources :projects, only: [:index, :create, :show, :update, :destroy] do
    get :settings, on: :member
    get :members, on: :member

    resources :identifier_sets, only: [:create, :update]
    resources :language_identifiers, only: [:update]
    resources :exports, controller: "exports", only: [:create, :show, :destroy] do
      get :download, on: :member
    end
    resources :languages, only: [:create, :update, :destroy] do
      patch :archive, on: :member
      patch :restore, on: :member
    end
    resources :sheets, only: [:index, :create, :show, :update] do
      post :import_preview, on: :collection
      get :settings, on: :member

      get :image, on: :member
      get :translations, on: :member
      get :history, on: :member, to: "recording_events#index"
      resources :recording_events, only: [] do
        get :change, on: :collection
        patch :restore, on: :member
      end
      resources :recordings, only: [:new, :edit, :create, :update, :destroy] do
        get :parents, on: :collection
        get :preview, on: :collection
        patch :translation, on: :member
        patch :pluralization, on: :member
      end
    end
    resources :project_invites, only: [:index, :create, :destroy]
    resources :project_memberships, only: [:edit, :update, :destroy]
  end
  resources :project_invites, only: [:index, :update]
  get "import-export", to: "formats#index", as: :import_export
  get "up" => "rails/health#show", as: :rails_health_check

  devise_for :users, controllers: { omniauth_callbacks: "users/omniauth_callbacks", sessions: "users/sessions", registrations: "users/registrations", passwords: "users/passwords" }
  post "users/email_code", to: "users/email_codes#create", as: nil
  get "users/email_code", to: "users/email_codes#show", as: :users_email_code
  patch "users/email_code", to: "users/email_codes#verify", as: nil
  post "users/email_code/resend", to: "users/email_codes#resend", as: :resend_users_email_code
  post "users/security_verification", to: "users/email_codes#security", as: :users_security_verification
  post "users/change_email", to: "users/email_codes#change_email", as: :users_change_email
  resource :authentication_methods, only: [:update, :destroy], controller: "users/authentication_methods"
  post "authentication_methods/:provider/link", to: "users/authentication_methods#link", as: :link_authentication_method

  namespace :settings do
    resources :projects, only: :index
    resources :users, only: [:index, :edit, :update, :destroy] do
      patch :ban, on: :member
    end
  end
  get "settings", to: redirect("/settings/users")

  root to: redirect("/users/sign_in")
end
