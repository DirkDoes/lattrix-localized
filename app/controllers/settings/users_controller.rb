class Settings::UsersController < Settings::BaseController
  before_action :ensure_users_index_access, only: [:index]
  before_action :ensure_user_edit_access, only: [:edit, :update]
  require_settings_access only: [:ban, :destroy]
  before_action :set_user, only: [:edit, :update, :destroy, :ban]
  before_action :set_role_options, only: [:edit, :update]

  def index
    @inactive = params[:status] == "inactive"
    active = manageable_users.where(banned_at: nil).where.not(email_verified_at: nil)
    @users = (@inactive ? manageable_users.where.not(id: active.select(:id)) : active).order(:email)
  end

  def edit
  end

  def update
    requested_role = user_params[:role]

    if requested_role.present? && !@role_options.include?(requested_role)
      @user.assign_attributes(user_params.except(:role))
      @user.errors.add(:role, "change is not allowed for your account")
      render :edit, status: :unprocessable_entity
      return
    end

    if @user.update(user_params)
      redirect_to after_update_path, notice: "User updated successfully."
    else
      set_role_options
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @user == current_user
      redirect_to settings_users_path, alert: "You cannot delete yourself."
    elsif @user.destroy
      redirect_to settings_users_path, notice: "User removed successfully."
    else
      redirect_to settings_users_path, alert: @user.errors.full_messages.to_sentence.presence || "User could not be removed."
    end
  end

  def ban
    if @user == current_user
      redirect_to edit_settings_user_path(@user), alert: "You cannot ban yourself."
    elsif @user.update(banned_at: @user.banned_at ? nil : Time.current)
      redirect_to edit_settings_user_path(@user), notice: "Access updated."
    else
      redirect_to edit_settings_user_path(@user), alert: @user.errors.full_messages.to_sentence
    end
  end

  private

  def ensure_users_index_access
    ensure_settings_access
  end

  def ensure_user_edit_access
    return if editing_self?
    return if settings_access?

    redirect_to overview_path, alert: "You don't have permission to access that page."
  end

  def set_user
    @user =
      if editing_self?
        current_user
      else
        manageable_users.find(params[:id])
      end
  rescue ActiveRecord::RecordNotFound
    redirect_to(settings_access? ? settings_users_path : overview_path, alert: "You don't have permission to manage that user.")
  end

  def user_params
    allowed_attributes = [:name]
    allowed_attributes << :theme_preference if editing_self?
    allowed_attributes << :role if can_edit_role?

    params.require(:user).permit(*allowed_attributes)
  end

  def after_update_path
    return settings_users_path unless @user == current_user
    return overview_path unless settings_access?

    edit_settings_user_path(@user)
  end

  def manageable_users
    owner? ? User.all : User.where(role: :viewer).or(User.where(id: current_user.id))
  end

  def set_role_options
    @can_edit_role = can_edit_role?
    return unless @can_edit_role

    @role_options =
      if owner?
        User.roles.keys
      elsif @user.admin?
        %w[admin viewer]
      else
        %w[viewer]
      end
  end

  def can_edit_role?
    settings_access?
  end

  def editing_self?
    current_user && params[:id].to_s == current_user.to_param
  end
end
