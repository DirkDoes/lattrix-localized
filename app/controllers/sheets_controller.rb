class SheetsController < ApplicationController
  layout "settings"
  after_action :verify_authorized
  after_action :verify_policy_scoped, only: :index
  allow_unauthenticated_access only: [:index, :show, :translations, :image]
  before_action :authenticate_private_sheet, only: [:index, :show, :translations, :image]
  before_action :set_project

  def index
    authorize @project, :show?
    load_sheet_page
    @sheet = @project.sheets.new
  end

  def create
    @sheet = @project.sheets.new(params.require(:sheet).permit(:name, :slug, :visibility, :default_language_id))
    authorize @sheet
    if @project.with_lock { @sheet.save }
      redirect_to project_sheet_path(@project, @sheet), notice: "Sheet created."
    else
      load_sheet_page
      render :index, status: :unprocessable_entity
    end
  end

  def show
    @sheet = readable_sheets.find_by!(slug: params[:id])
    authorize @sheet
    redirect_to translations_project_sheet_path(@project, @sheet)
  end

  def image
    @sheet = readable_sheets.find_by!(slug: params[:id])
    authorize @sheet, :image?
    return head :not_found if @sheet.image_data.blank?
    expires_in 1.day, public: false
    response.strong_etag = Digest::SHA256.hexdigest(@sheet.image_data)
    return head :not_modified if request.fresh?(response)
    send_data @sheet.image_data, type: "image/webp", disposition: "inline"
  end

  def translations
    @sheet = readable_sheets.find_by!(slug: params[:id])
    authorize @sheet, :translations?
    @tree = @sheet.translation_tree
    if params[:after].present? && params[:revision].to_s != @tree.revision.to_s
      return render partial: "sheets/changed"
    end
    @languages = @sheet.active_languages.order(:name).to_a
    main_set = @project.identifier_sets.order(:created_at, :id).first
    @language_identifiers = main_set ? main_set.language_identifiers.pluck(:language_id, :identifier).to_h : {}
    @languages.each { |language| @language_identifiers[language.id] ||= language.identifier }
    @editable_languages = @languages.select { |language| policy(@sheet).edit_language?(language) }.map(&:id)
    @left = @languages.find { |language| @language_identifiers[language.id] == params[:left] } || @languages.find { |language| language.id == @sheet.default_language_id } || @languages.first
    editable = @languages.select { |language| @editable_languages.include?(language.id) }
    @right = @languages.find { |language| @language_identifiers[language.id] == params[:right] } || (editable - [@left]).first || editable.first || (@languages - [@left]).first || @left
    @batch_size = params[:after].present? ? 20 : params.fetch(:loaded, 20).to_i.clamp(20, 10_000)
    @view = params[:view] == "tree" && params[:mobile] != "1" ? "tree" : "keys"
    @sort = params[:sort].presence_in(%w[alphabetical recent relevance]) || "alphabetical"
    @query = params[:q].to_s.strip.first(200)
    @rows = @tree.key_rows(hide_parents: !@sheet.allow_parent_translations?, query: @query, group_plurals: true,view: @view, sort: @sort, languages: [@left&.id, @right&.id].compact.uniq, after: params[:after], limit: @batch_size + 1)
    @more = @rows.length > @batch_size
    @rows = @rows.first(@batch_size)
    @records = @tree.recordings.where(id: @rows.map { |row| row['id'] }).includes(:recordable).index_by(&:id)
    @plural_children = if @sheet.pluralization_enabled?
      @tree.recordings.active.keys.where(parent_id: @records.values.select { |r| r.recordable.pluralized }.map(&:id)).includes(:recordable).to_a.select { |r| @sheet.plural_categories.include?(r.recordable.name) }.group_by(&:parent_id)
    else
      {}
    end
    @form_keys = @records.values + @plural_children.values.flatten
    @keys_with_children = @tree.recordings.active.keys.where(parent_id: @form_keys.map(&:id)).distinct.pluck(:parent_id)
    @values = @tree.recordings.active.texts.where(parent_id: @form_keys.map(&:id)).joins("JOIN text_translations ON text_translations.id=recordings.recordable_id").where(text_translations: {language_id: [@left&.id, @right&.id, @sheet.default_language_id].compact}).includes(:recordable).index_by { |value| [value.parent_id, value.recordable.language_id] }

    @manage_keys = policy(@sheet).manage_keys?
    @reveal_plurals = policy(@sheet).reveal_plurals?
    if params[:after].present?
      render partial: "sheets/rows_page"
    end
  end

  def settings
    @sheet = readable_sheets.find_by!(slug: params[:id])
    authorize @sheet, :settings?
  end

  def update
    settings
    @sheet.project.with_lock do
      @sheet.translation_tree.lock!
      original_slug = @sheet.slug
      attributes = params.require(:sheet).permit(:name, :description, :slug, :delimiter, :case_sensitive_keys, :allow_parent_translations, :pluralization_enabled, :missing_value_behavior, :default_language_id)
      if attributes.key?(:slug) && attributes[:slug].strip.downcase != @sheet.slug
        authorize @sheet, :change_slug?
        @sheet.assign_attributes(attributes)
        raise ActiveRecord::RecordInvalid, @sheet unless @sheet.valid?
        if params[:confirm_slug] != "1"
          @requested_slug = @sheet.slug
          @sheet.slug = original_slug
          return render :settings
        end
      end
      upload = params.dig(:sheet, :image)
      attributes[:image_data] = ProfilePhoto.convert(upload.read(ProfilePhoto::MAX_BYTES + 1)) if upload.respond_to?(:read)
      attributes[:image_data] = nil if params.dig(:sheet, :remove_image) == "1"
      @sheet.update!(attributes)
      if @sheet.saved_change_to_pluralization_enabled? && @sheet.pluralization_enabled?
        @sheet.translation_tree.recordings.active.keys.joins("JOIN translation_keys k ON k.id=recordings.recordable_id").where("k.pluralized").find_each { |key| key.set_pluralized!(true, actor: current_user) }
      end
    end
    redirect_to settings_project_sheet_path(@project, @sheet), notice: "Sheet settings updated."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid, ArgumentError, ProfilePhoto::Invalid => error
    @sheet.slug = @sheet.slug_in_database if @sheet.persisted?
    flash.now[:alert] = error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages.uniq.to_sentence : error.message.lines.first
    @delimiter_error = @sheet.errors[:delimiter].presence&.join(" ") || (error.message.lines.first if error.message.downcase.include?("delimiter"))
    render :settings, status: :unprocessable_entity
  end


  private

  def authenticate_private_sheet
    return if current_user
    project = policy_scope(Project).find_by(slug: params[:project_id])
    public_page = project && (action_name == "index" || policy_scope(project.sheets).exists?(slug: params[:id]))
    authenticate_user! unless public_page
  end

  def load_sheet_page
    scope = readable_sheets.order(:name, :id)
    @pages = [(scope.count + 8) / 9, 1].max
    @page = params[:page].to_i.clamp(1, @pages)
    @sheets = scope.limit(9).offset((@page - 1) * 9)
  end

  def readable_sheets
    policy_scope(@project.sheets)
  end

  def set_project
    @project = policy_scope(Project).find_by!(slug: params[:project_id])
  end
end
