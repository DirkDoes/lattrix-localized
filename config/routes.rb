Rails.application.routes.draw do
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
    resources :users, only: [:index, :edit, :update, :destroy] do
      patch :ban, on: :member
    end
  end
  get "settings", to: redirect("/settings/users")

  root to: redirect("/users/sign_in")
  get "overview", to: "overview#show", as: :overview
end
