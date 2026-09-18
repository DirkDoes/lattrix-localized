require "vips"
require "net/http"

class ProfilePhoto
  class Invalid < StandardError; end
  MAX_BYTES = 5.megabytes
  TYPES = %w[image/jpeg image/png image/webp image/gif image/tiff image/bmp image/x-ms-bmp image/heic image/heif image/avif].freeze
  HOSTS = {
    "google" => %w[googleusercontent.com],
    "github" => %w[avatars.githubusercontent.com],
    "discord" => %w[cdn.discordapp.com media.discordapp.net]
  }.freeze

  def self.convert(data)
    raise Invalid, "Choose an image up to 5 MB." if data.blank? || data.bytesize > MAX_BYTES
    raise Invalid, "Choose a supported raster image (JPEG, PNG, WebP, GIF, TIFF, BMP, HEIC or AVIF)." unless TYPES.include?(Marcel::MimeType.for(StringIO.new(data)))
    image = Vips::Image.new_from_buffer(data, "", access: :sequential)
    raise Invalid, "Choose an image with at most 40 million pixels." if image.width * image.height > 40_000_000
    Vips::Image.thumbnail_buffer(data, 512, height: 512, size: :down).webpsave_buffer(Q: 80, strip: true)
  rescue Vips::Error
    raise Invalid, "This image could not be read. Try a JPEG, PNG or WebP image."
  end

  def self.fetch(provider, url, redirects = 0)
    uri = URI.parse(url.to_s)
    hosts = HOSTS.fetch(provider, [])
    unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? &&
        hosts.any? { |host| uri.host == host || (provider == "google" && uri.host&.end_with?(".#{host}")) }
      raise Invalid, "Invalid provider photo URL."
    end
    data = +"".b
    Net::HTTP.start(uri.host, 443, use_ssl: true, open_timeout: 3, read_timeout: 3, write_timeout: 3) do |http|
      http.request(Net::HTTP::Get.new(uri.request_uri)) do |response|
        if response.is_a?(Net::HTTPRedirection) && redirects < 2
          return fetch(provider, URI.join(uri.to_s, response.fetch("location")).to_s, redirects + 1)
        end
        raise Invalid, "Provider photo unavailable." unless response.is_a?(Net::HTTPSuccess)
        response.read_body do |chunk|
          data << chunk
          raise Invalid, "Provider photo is too large." if data.bytesize > MAX_BYTES
        end
      end
    end
    data
  end

  def self.import(user, provider, url)
    return if url.blank? || user.profile_photo_customized? || user.profile_photo.present?
    data = convert(fetch(provider, url))
    user.with_lock do
      user.update!(profile_photo: data) unless user.profile_photo_customized? || user.profile_photo.present?
    end
  rescue Invalid, URI::InvalidURIError, SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, KeyError
    # A provider avatar is optional; failed downloads must not interrupt authentication.
    nil
  end
end
