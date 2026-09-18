class ProfilePhotosController < ApplicationController
  allow_unauthenticated_access only: :show

  def show
    user = User.find_signed(params[:id], purpose: :profile_photo)
    return head :not_found if user.nil? || user.profile_photo.blank?
    expires_in 1.day, public: false
    response.strong_etag = Digest::SHA256.hexdigest(user.profile_photo)
    return head :not_modified if request.fresh?(response)
    send_data user.profile_photo, type: "image/webp", disposition: "inline", filename: "profile.webp"
  end

  def update
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
    current_user.update!(profile_photo: nil, profile_photo_customized: true)
    redirect_to edit_settings_user_path(current_user), notice: "Profile picture removed."
  end
end
