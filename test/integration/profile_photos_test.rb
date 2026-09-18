require "test_helper"
require "minitest/mock"

class ProfilePhotosTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    sign_in @user
    @png = Vips::Image.black(800, 600).new_from_image([ 70, 110, 220 ]).pngsave_buffer
  end

  def upload(data, type = "image/png")
    Tempfile.create([ "photo", ".png" ]) do |file|
      file.binmode
      file.write(data)
      file.flush
      patch profile_photo_path, params: { photo: Rack::Test::UploadedFile.new(file.path, type), user_id: users(:two).id }
    end
  end

  test "uploads are converted, resized, displayed and only change self" do
    upload(@png)
    assert_redirected_to edit_settings_user_path(@user)
    @user.reload
    assert @user.profile_photo_customized?
    assert_nil users(:two).profile_photo
    image = Vips::Image.new_from_buffer(@user.profile_photo, "")
    assert_equal "image/webp", Marcel::MimeType.for(StringIO.new(@user.profile_photo))
    assert_equal [ 512, 384 ], [ image.width, image.height ]
    get edit_settings_user_path(@user)
    assert_select "se-profile[image*='/profile_photos/']", minimum: 2
    get profile_photo_image_path(@user.signed_id(purpose: :profile_photo))
    assert_response :success
    assert_equal "image/webp", response.media_type
    assert_equal @user.profile_photo, response.body.b
    get profile_photo_image_path(@user.id)
    assert_response :not_found
  end

  test "photos are privately cached and photo content alone versions the URL" do
    upload(@png)
    @user.reload
    helper = self.extend(ApplicationHelper)
    original_url = helper.profile_photo_url_for(@user)
    get original_url
    assert_response :success
    assert_includes response.headers["Cache-Control"], "private"
    assert_includes response.headers["Cache-Control"], "max-age=86400"
    assert_not_includes response.headers["Cache-Control"], "no-store"
    etag = response.headers["ETag"]
    assert etag.present?
    get original_url, headers: { "If-None-Match" => etag }
    assert_response :not_modified
    assert_empty response.body

    @user.update!(name: "Changed name")
    assert_equal original_url, helper.profile_photo_url_for(@user)
    replacement = Vips::Image.black(100, 100).new_from_image([ 220, 70, 110 ]).pngsave_buffer
    upload(replacement)
    new_url = helper.profile_photo_url_for(@user.reload)
    assert_not_equal original_url, new_url
    get new_url, headers: { "If-None-Match" => etag }
    assert_response :success
    assert_not_equal etag, response.headers["ETag"]
    assert_equal @user.profile_photo, response.body.b
    delete profile_photo_path
    assert_nil helper.profile_photo_url_for(@user.reload)
    get new_url
    assert_response :not_found
  end

  test "invalid oversized and vector uploads preserve existing photo with inline errors" do
    upload(@png)
    original = @user.reload.profile_photo
    [ "not an image", "<svg xmlns='http://www.w3.org/2000/svg'></svg>", "x" * (ProfilePhoto::MAX_BYTES + 1) ].each do |data|
      upload(data)
      assert_response :unprocessable_entity
      assert_select "se-modal#profile-photo-modal[open] se-text[role=alert]"
      assert_equal original, @user.reload.profile_photo
    end
    patch profile_photo_path
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.profile_photo
  end

  test "provider imports never replace an upload or restore an explicitly removed photo" do
    ProfilePhoto.stub(:fetch, @png) do
      ProfilePhoto.import(@user, "google", "https://lh3.googleusercontent.com/avatar")
      assert @user.reload.profile_photo.present?
      assert_not @user.profile_photo_customized?
      upload(@png)
    end
      ProfilePhoto.stub(:fetch, ->(*) { flunk "Customized photos must not be downloaded" }) do
        ProfilePhoto.import(@user.reload, "github", "https://avatars.githubusercontent.com/u/1")
        delete profile_photo_path
        assert_redirected_to edit_settings_user_path(@user)
        ProfilePhoto.import(@user.reload, "discord", "https://cdn.discordapp.com/avatars/1/test.png")
      end
      assert_nil @user.reload.profile_photo
      assert @user.profile_photo_customized?
  end

  test "provider URL restrictions and unavailable photos" do
    %w[http://avatars.githubusercontent.com/u/1 https://localhost/image https://avatars.githubusercontent.com.evil.test/x https://user:pass@avatars.githubusercontent.com/x https://avatars.githubusercontent.com:444/x].each do |url|
      assert_raises(ProfilePhoto::Invalid) { ProfilePhoto.fetch("github", url) }
    end
    ProfilePhoto.stub(:fetch, ->(*) { raise SocketError }) do
      assert_nil ProfilePhoto.import(@user, "google", "https://lh3.googleusercontent.com/avatar")
    end
    assert_nil @user.reload.profile_photo
    sign_out @user
    patch profile_photo_path
    assert_redirected_to new_user_session_path
    delete profile_photo_path
    assert_redirected_to new_user_session_path
  end
end
