Rails.application.routes.draw do
  get "REVISION.txt", to: ->(_env) { [200, { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" }, [Rails.root.join("REVISION.txt").read]] }

  resource :profile_photo, only: [:update, :destroy]
  get "profile_photos/:id", to: "profile_photos#show", as: :profile_photo_image
  resources :projects, only: [:index, :create, :show, :update, :destroy] do
    get :settings, on: :member
    get :members, on: :member

    get :translations, on: :member, to: "catalog#translations"
    get :pending, on: :member, to: "catalog#pending"
    get :incoming, on: :member, to: "catalog#incoming"
    get :pending_diff, on: :member, to: "catalog#pending_diff"
    get :history, on: :member, to: "catalog#history"
    get :history_events, on: :member, to: "catalog#history_events"
    get :export, on: :member, to: "catalog#export"
    post :catalog_change, on: :member, to: "catalog#change"
    post :review, on: :member, to: "catalog#review"
    post :restore_catalog, on: :member, to: "catalog#restore"
    post :resolve, on: :member, to: "catalog#resolve"
    post :sync, on: :member, to: "catalog#sync"
    get :sync_status, on: :member, to: "catalog#sync_status"
    post :connect, on: :member, to: "catalog#connect"
    post :source_locale, on: :member, to: "catalog#source_locale"
    resources :languages, only: [:create] do
      patch :archive, on: :member
      patch :restore, on: :member
    end
    resources :project_invites, only: [:index, :create, :destroy]
    resources :project_memberships, only: [:edit, :update, :destroy]
  end
  resources :project_invites, only: [:index, :update]
  get "import-export", to: "formats#index", as: :import_export
  post "github/webhook", to: "github_webhooks#create"
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
    resource :github_app, only: [:show, :update]
    resources :projects, only: :index
    resources :users, only: [:index, :edit, :update, :destroy] do
      patch :ban, on: :member
    end
  end
  get "settings", to: redirect("/settings/users")

  authenticated :user do
    root to: redirect("/projects"), as: :authenticated_root
  end
  root to: redirect("/users/sign_in")
end
