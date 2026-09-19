class OverviewController < ApplicationController
  layout "settings"
  after_action :verify_authorized

  def show
    authorize :application, :access?
  end
end
