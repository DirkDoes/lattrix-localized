class Settings::UsersController < Settings::BaseController
  include TableResults
  before_action :set_user, only: [:edit, :update, :destroy, :ban]
  before_action :set_role_options, only: [:edit, :update]

  def index
    authorize User
    @banned = params[:status] == "banned"
    users = policy_scope(User)
    @users = table_results((@banned ? users.where.not(banned_at: nil) : users.where(banned_at: nil)).order(:email, :id), columns: %w[users.name users.email])
  end

  def edit
  end

  def update
    requested_role = user_params[:role]
    if requested_role.present? && !@role_options.include?(requested_role)
      @user.assign_attributes(user_params.except(:role))
      @user.errors.add(:role, "change is not allowed for your account")
      return render :edit, status: :unprocessable_entity
    end
    if @user.update(user_params)
      redirect_to after_update_path, notice: "User updated successfully."
    else
      set_role_options
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @user.destroy_with_workspace_transfer!(current_user)
    redirect_to settings_users_path, notice: "User removed. Any solely owned workspaces were transferred to you."
  rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => error
    redirect_to settings_users_path, alert: error.record.errors.full_messages.to_sentence.presence || error.message
  end

  def ban
    destination = params[:return_to] == "users" ? settings_users_path(status: params[:status] == "banned" ? "banned" : "active", q: params[:q].to_s.first(200), page: params[:page]) : edit_settings_user_path(@user)
    if @user.update(banned_at: @user.banned_at ? nil : Time.current)
      redirect_to destination, notice: "Access updated.", status: :see_other
    else
      redirect_to destination, alert: @user.errors.full_messages.to_sentence, status: :see_other
    end
  end

  private

  def set_user
    @user = policy_scope(User).find(params[:id])
    authorize @user
  rescue ActiveRecord::RecordNotFound
    # No record is exposed; guests/members can resolve only their own account.
    skip_authorization
    redirect_to policy(User).index? ? settings_users_path : overview_path,
      alert: "You don't have permission to manage that user."
  end

  def user_params
    params.require(:user).permit(*policy(@user).permitted_attributes)
  end

  def set_role_options
    @role_options = policy(@user).role_options
    @can_edit_role = @role_options.any?
  end

  def after_update_path
    return settings_users_path unless @user == current_user
    return overview_path unless policy(User).index?
    edit_settings_user_path(@user)
  end
end
