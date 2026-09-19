module ApplicationHelper
  def profile_initials(name)
    name.to_s.gsub(/[^\p{L}\p{N}\s]/, "").split.first(2).map { |word| word.first }.join.upcase.first(2)
  end

  def profile_photo_url_for(user)
    profile_photo_image_path(user.signed_id(purpose: :profile_photo), v: Digest::SHA256.hexdigest(user.profile_photo)) if user.profile_photo.present?
  end

  def authentication_icon(method)
    case method
    when "github"
      { light: "/icons/GitHub_dark.svg", dark: "/icons/GitHub_light.svg", preserveLightColors: true, preserveDarkColors: true }.to_json
    when "google", "discord" then "/icons/#{method}.svg"
    when "password" then "lock"
    else "mail"
    end
  end
end
