module ApplicationHelper
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
