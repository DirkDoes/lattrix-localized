require "test_helper"
class SheetDetailsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  setup do
    @user=users(:one); @user.update!(email_verified_at:Time.current,role: :member); sign_in @user
    @project=Project.create!(name:"Details")
    @membership=@project.project_memberships.create!(user:@user,role:"admin")
    @sheet=@project.sheets.create!(name:"Website")
  end
  test "dashboards route to useful pages" do
    get project_path(@project)
    assert_redirected_to project_sheets_path(@project)
    get project_sheet_path(@project,@sheet)
    assert_redirected_to translations_project_sheet_path(@project,@sheet)
    get settings_project_sheet_path(@project,@sheet)
    assert_select 'se-sidebar-button[label=Dashboard]', count:0
    assert_select 'se-nav-tabs' do |tabs|
      assert_not_includes tabs.first['options'], 'Dashboard'
    end
  end
  test "admins edit details but only owners can confirm unique identifiers" do
    patch project_sheet_path(@project,@sheet),params:{sheet:{description:"Optional details",name:"Renamed"}}
    assert_response :redirect
    assert_equal "Optional details",@sheet.reload.description
    old_path=project_sheet_path(@project,@sheet)
    patch old_path,params:{sheet:{slug:"changed"},confirm_slug:"1"}
    assert_response :forbidden
    @membership.update!(role:"owner")
    patch old_path,params:{sheet:{slug:"changed"}}
    assert_response :success
    assert_select 'se-modal[open] input[name=confirm_slug]'
    assert_equal "website",@sheet.reload.slug
    @project.sheets.create!(name:"Taken",slug:"changed")
    patch old_path,params:{sheet:{slug:"changed"},confirm_slug:"1"}
    assert_response :unprocessable_entity
    patch old_path,params:{sheet:{slug:"new_identifier"},confirm_slug:"1"}
    assert_response :redirect
    assert_equal "new_identifier",@sheet.reload.slug
    get old_path
    assert_response :not_found
  end
  test "images are converted, optional, and protected by sheet access" do
    tempfile=Tempfile.new(['sheet','.png'])
    tempfile.binmode
    tempfile.write(Vips::Image.black(20,20).pngsave_buffer); tempfile.close
    image=Rack::Test::UploadedFile.new(tempfile.path,'image/png')
    patch project_sheet_path(@project,@sheet),params:{sheet:{image:image}}
    assert_response :redirect
    assert_equal 'image/webp',Marcel::MimeType.for(StringIO.new(@sheet.reload.image_data))
    get image_project_sheet_path(@project,@sheet)
    assert_response :success
    sign_out @user
    get image_project_sheet_path(@project,@sheet)
    assert_response :redirect
    sign_in @user
    patch project_sheet_path(@project,@sheet),params:{sheet:{remove_image:'1'}}
    assert_nil @sheet.reload.image_data
  ensure
    tempfile&.unlink
  end
end
