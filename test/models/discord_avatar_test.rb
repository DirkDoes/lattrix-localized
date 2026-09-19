require "test_helper"
require "minitest/mock"
require Rails.root.join("lib/discord_strategy")

class DiscordAvatarTest < ActiveSupport::TestCase
  test "strategy supplies static CDN avatars including animated hashes and default avatars" do
    strategy = OmniAuth::Strategies::Discord.new(nil)
    raw = { "id" => "123456789012345678", "username" => "Test", "email" => "test@example.com", "avatar" => "a_avatarhash", "discriminator" => "0" }
    strategy.stub(:raw_info, raw) do
      assert_equal "https://cdn.discordapp.com/avatars/123456789012345678/a_avatarhash.png?size=512", strategy.info[:image]
      raw["avatar"] = "statichash"
      assert_equal "https://cdn.discordapp.com/avatars/123456789012345678/statichash.png?size=512", strategy.info[:image]
      raw["avatar"] = nil
      assert_equal "https://cdn.discordapp.com/embed/avatars/#{(raw["id"].to_i >> 22) % 6}.png", strategy.info[:image]
      raw["discriminator"] = "1234"
      assert_equal "https://cdn.discordapp.com/embed/avatars/4.png", strategy.info[:image]
    end
  end

  test "animated GIF conversion keeps only its first frame as WebP" do
    first = Vips::Image.black(16, 16).new_from_image([255, 0, 0])
    second = Vips::Image.black(16, 16).new_from_image([0, 0, 255])
    animation = first.join(second, :vertical)
    animation.set_type(GObject::GINT_TYPE, "page-height", 16)
    gif = animation.gifsave_buffer
    assert_equal 2, Vips::Image.new_from_buffer(gif, "", n: -1).get("n-pages")
    converted = ProfilePhoto.convert(gif)
    assert_equal "image/webp", Marcel::MimeType.for(StringIO.new(converted))
    image = Vips::Image.new_from_buffer(converted, "")
    assert_equal [16, 16], [image.width, image.height]
    pixel = image.getpoint(8, 8)
    assert_operator pixel[0], :>, pixel[2]
  end
end
