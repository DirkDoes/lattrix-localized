class ProfilePhotosController < ApplicationController
  allow_unauthenticated_access only: :show
  after_action :verify_authorized

  def show
    user = User.find_signed(params[:id], purpose: :profile_photo)
    if user.nil? || user.profile_photo.blank?
      skip_authorization # Invalid signed token: no record or photo is exposed.
      return head :not_found
    end
    authorize user, :public_photo?
    expires_in 1.day, public: false
    response.strong_etag = Digest::SHA256.hexdigest(user.profile_photo)
    return head :not_modified if request.fresh?(response)
    send_data user.profile_photo, type: "image/webp", disposition: "inline", filename: "profile.webp"
  end

  def update
    authorize current_user, :manage_account?
    upload = params[:photo]
    raise ProfilePhoto::Invalid, "Choose an image to upload." unless upload.respond_to?(:read)
    data = ProfilePhoto.convert(upload.read(ProfilePhoto::MAX_BYTES + 1))
    current_user.update!(profile_photo: data, profile_photo_customized: true)
    redirect_to edit_settings_user_path(current_user), notice: "Profile picture updated."
  rescue ProfilePhoto::Invalid => error
    @user = current_user
    @photo_error = error.message
    render "settings/users/edit", layout: "settings", status: :unprocessable_entity
  end

  def destroy
    authorize current_user, :manage_account?
    current_user.update!(profile_photo: nil, profile_photo_customized: true)
    redirect_to edit_settings_user_path(current_user), notice: "Profile picture removed."
  end
end
