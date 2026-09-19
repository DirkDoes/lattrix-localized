Rails.application.routes.draw do
  resource :profile_photo, only: [:update, :destroy]
  get "profile_photos/:id", to: "profile_photos#show", as: :profile_photo_image
  resources :workspaces, only: [:index, :create, :show, :update, :destroy] do
    get :settings, on: :member
    get :members, on: :member
    resources :projects, only: [:index, :create, :show] do
      get :translations, on: :member
    end
    resources :workspace_invites, only: [:index, :create, :destroy]
    resources :workspace_memberships, only: [:edit, :update, :destroy]
  end
  resources :workspace_invites, only: [:index, :update]
  get "up" => "rails/health#show", as: :rails_health_check

  devise_for :users, controllers: { omniauth_callbacks: "users/omniauth_callbacks", sessions: "users/sessions", registrations: "users/registrations", passwords: "users/passwords" }
  post "users/email_code", to: "users/email_codes#create", as: nil
  get "users/email_code", to: "users/email_codes#show", as: :users_email_code
  patch "users/email_code", to: "users/email_codes#verify", as: nil
  post "users/security_verification", to: "users/email_codes#security", as: :users_security_verification
  post "users/change_email", to: "users/email_codes#change_email", as: :users_change_email
  resource :authentication_methods, only: [:update, :destroy], controller: "users/authentication_methods"
  post "authentication_methods/:provider/link", to: "users/authentication_methods#link", as: :link_authentication_method

  namespace :settings do
    resources :workspaces, only: :index
    resources :users, only: [:index, :edit, :update, :destroy] do
      patch :ban, on: :member
    end
  end
  get "settings", to: redirect("/settings/users")

  root to: redirect("/users/sign_in")
  get "overview", to: "overview#show", as: :overview
end
