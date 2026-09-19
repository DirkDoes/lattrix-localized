require "omniauth-oauth2"

# Uses OmniAuth's OAuth2 state validation, token exchange and CSRF protection.
module OmniAuth
  module Strategies
    class Discord < OmniAuth::Strategies::OAuth2
      option :name, "discord"
      option :client_options, site: "https://discord.com/api/", authorize_url: "https://discord.com/oauth2/authorize", token_url: "oauth2/token"
      option :scope, "identify email"
      uid { raw_info.fetch("id").to_s }
      info { { email: raw_info["email"], nickname: raw_info["username"], name: raw_info["global_name"] || raw_info["username"], image: avatar_url } }
      extra { { raw_info: raw_info } }

      def avatar_url
        if raw_info["avatar"].present?
          "https://cdn.discordapp.com/avatars/#{raw_info.fetch('id')}/#{raw_info['avatar']}.png?size=512"
        else
          discriminator = raw_info["discriminator"].to_i
          index = discriminator.zero? ? (raw_info.fetch("id").to_i >> 22) % 6 : discriminator % 5
          "https://cdn.discordapp.com/embed/avatars/#{index}.png"
        end
      end

      def raw_info
        @raw_info ||= access_token.get("users/@me").parsed
      end

      def callback_url
        full_host + script_name + callback_path
      end
    end
  end
end

DiscordStrategy = OmniAuth::Strategies::Discord
