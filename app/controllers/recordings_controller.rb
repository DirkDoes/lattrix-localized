class RecordingsController < ApplicationController
  before_action :set_sheet
  after_action :verify_authorized

  def new
    authorize @sheet, :manage_keys?
    @languages = @sheet.active_languages.order(:name).to_a
    parent = @tree.recordings.active.keys.find(params[:parent_id]) if params[:parent_id].present?
    render partial: "sheets/key_modal", locals: {key: nil, parent: parent}
  end

  def edit
    authorize @sheet, :manage_keys?
    key = @tree.recordings.active.keys.includes(:recordable).find(params[:id])
    @languages = @sheet.active_languages.order(:name).to_a
    render partial: params[:remove] == "1" ? "sheets/key_removal" : "sheets/key_modal", locals: {key: key, parent: key.parent}
  end

  def parents
    authorize @sheet, :manage_keys?
    query = params[:q].to_s.strip.first(200)
    rows = query.length < 3 ? [] : @tree.key_rows(query: query, limit: 20, group_plurals: false)
    render json: rows.map { |row| {id: row['id'], label: row['path']} }
  end

  def preview
    authorize @sheet, :manage_keys?
    parent, name = resolve_key_path(preview: true)
    render json: {valid: true, name: name, parent: parent ? key_path(parent) : nil, parent_id: parent&.id, levels: @path_levels, existing: @path_existing, missing_parent: @missing_parent}
  rescue ActiveRecord::RecordNotFound, ArgumentError => error
    render json: {valid: false, error: error.is_a?(ActiveRecord::RecordNotFound) ? "Parent key does not exist" : error.message}
  end

  def create
    authorize @sheet, :manage_keys?
    @tree.with_lock do
      parent, name = resolve_key_path(create_missing: true)
      key = Recording.create_key!(tree: @tree, parent: parent, name: name, description: params[:description].to_s)
      key.set_pluralized!(true) if params[:pluralized] == "1"
      save_form_translations(key, creating: true)
    end
    complete("Key added.")
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ActiveRecord::StatementInvalid, ArgumentError => error
    failed(error)
  end

  def translation
    language = @sheet.active_languages.find(params[:language_id])
    authorize @sheet, :show?
    raise Pundit::NotAuthorizedError unless policy(@sheet).edit_language?(language)
    key = @tree.recordings.active.keys.find(params[:id])
    raise ArgumentError, "Edit version is required" unless params.key?(:version)
    value = key.save_translation!(language, params[:text].to_s, expected: params[:version], existing_id: params[:translation_id])
    render json: {text: value&.recordable&.text.to_s, version: value&.lock_version || "new", translation_id: value&.id}
  rescue ActiveRecord::StaleObjectError
    current = key.children.active.texts.includes(:recordable).find { |r| r.recordable.language_id == language.id }
    render json: {error: "This translation changed while you were editing. Review the current value before saving again.", text: current&.recordable&.text.to_s, version: current&.lock_version || "new", translation_id: current&.id}, status: :conflict
  rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid, ArgumentError => error
    render json: {error: clean_error(error)}, status: :unprocessable_entity
  end

  def update
    authorize @sheet, :manage_keys?
    key = @tree.recordings.active.keys.find(params[:id])
    @tree.with_lock do
      parent, name = resolve_key_path(create_missing: true)
      key.change_key!(name: name, parent_id: parent&.id, description: params[:description].to_s, expected: params.require(:version))
      if key.recordable.pluralized
        key.set_pluralized!(params[:pluralized] == "1") if params.key?(:pluralized)
        save_form_translations(key)
      else
        save_form_translations(key)
        key.set_pluralized!(params[:pluralized] == "1") if params.key?(:pluralized)
      end
    end
    complete("Key and its subtree updated.")
  rescue ActiveRecord::RecordNotFound, ActiveRecord::StaleObjectError, ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid, ArgumentError => error
    failed(error)
  end

  def destroy
    authorize @sheet, :manage_keys?
    key = @tree.recordings.active.keys.find(params[:id])
    key.discard_subtree!(expected: params.require(:version))
    complete("Key and its subtree removed.")
  rescue ActiveRecord::StaleObjectError, ArgumentError => error
    failed(error)
  end

  def pluralization
    authorize @sheet, :manage_keys?
    key = @tree.recordings.active.keys.find(params[:id])
    @tree.with_lock do
      key.reload
      raise ActiveRecord::StaleObjectError.new(key, "update") unless key.lock_version == params.require(:version).to_i
      key.set_pluralized!(params[:enabled] == "1")
    end
    complete("Plural editor updated; child keys are preserved.")
  rescue ActiveRecord::RecordNotFound, ActiveRecord::StaleObjectError, ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid, ArgumentError => error
    failed(error)
  end

  private
  def key_path(key)
    parts = []
    while key
      parts.unshift(key.recordable.name)
      key = key.parent
    end
    parts.join(@sheet.delimiter)
  end
  helper_method :key_path

  def sibling(parent, name)
    @tree.recordings.active.keys.where(parent_id: parent&.id).joins("JOIN translation_keys k ON k.id=recordings.recordable_id")
      .where(@sheet.case_sensitive_keys? ? "k.name = ?" : "lower(k.name) = lower(?)", name).first
  end

  def resolve_key_path(preview: false, create_missing: false)
    name = params[:name].to_s
    raise ArgumentError, "Enter a key name" if name.empty?
    raise ArgumentError, "Key names cannot contain whitespace" if name.match?(/[[:space:]]/)
    parent = @tree.recordings.active.keys.find(params[:parent_id]) if params[:parent_id].present? && params[:parent_id] != "root"
    @path_levels = parent ? key_path(parent).split(@sheet.delimiter) : []
    @path_existing = @path_levels.map { true }; @missing_parent = false
    parts = name.split(@sheet.delimiter, -1)
    raise ArgumentError, "Each part of the path needs a name" if parts.any?(&:blank?)
    raise ArgumentError, "Key names cannot exceed 200 characters" if parts.any? { |part| part.length > 200 }
    name = parts.pop
    parts.each do |part|
      found = sibling(parent, part) unless @missing_parent
      @path_levels << (found ? found.recordable.name : part)
      @path_existing << found.present?
      if found
        parent = found
      elsif create_missing
        parent = Recording.create_key!(tree: @tree, parent: parent, name: part)
      elsif preview
        @missing_parent = true
      else
        raise ArgumentError, "Parent path does not exist"
      end
    end
    existing = sibling(parent, name) unless @missing_parent
    raise ArgumentError, "This key name already exists" if existing && existing.id.to_s != params[:id].to_s
    @path_levels << name; @path_existing << false
    [parent, name]
  end

  def save_form_translations(key, creating: false)
    rows = params[:translation_rows]&.values || []
    # Keep the simple API payload supported alongside the modal's rows.
    rows += (params[:translations]&.to_unsafe_h || {}).map { |id, text| {language_id: id, text: text} }
    ids = rows.reject { |row| row[:translation_id].present? && row[:text].to_s.empty? }.map { |row| row[:language_id].presence }.compact
    raise ArgumentError, "Select each language only once" if ids.uniq != ids
    target = key
    if key.recordable.pluralized && @sheet.pluralization_enabled?
      target = key.children.active.keys.joins("JOIN translation_keys k ON k.id=recordings.recordable_id").find_by!("k.name = 'other'")
    end
    rows.each do |row|
      next if row[:language_id].blank? && row[:text].to_s.empty?
      language = @sheet.active_languages.find(row[:language_id])
      raise Pundit::NotAuthorizedError unless policy(@sheet).edit_language?(language)
      options = creating ? {} : {expected: row[:version].presence || "new", existing_id: row[:translation_id]}
      if !creating && row[:translation_id].present?
        original = target.children.active.texts.includes(:recordable).find_by(id: row[:translation_id])
        raise ActiveRecord::StaleObjectError.new(target, "update") unless original
        if original.recordable.language_id != language.id
          raise Pundit::NotAuthorizedError unless policy(@sheet).edit_language?(original.recordable.language)
          target.save_translation!(original.recordable.language, "", **options)
          options = {expected: "new"}
        end
      end
      target.save_translation!(language, row[:text].to_s, **options)
    end
  end

  def set_sheet
    @project = policy_scope(Project).find_by!(slug: params[:project_id])
    @sheet = policy_scope(@project.sheets).find_by!(slug: params[:sheet_id])
    @tree = @sheet.translation_tree
  end
  def complete(message)
    respond_to do |format|
      format.json { render json: {location: translations_project_sheet_path(@project, @sheet)} }
      format.html { redirect_to translations_project_sheet_path(@project, @sheet), notice: message, status: :see_other }
    end
  end

  def failed(error)
    respond_to do |format|
      format.json { render json: {error: clean_error(error)}, status: :unprocessable_entity }
      format.html { redirect_to translations_project_sheet_path(@project, @sheet), alert: clean_error(error), status: :see_other }
    end
  end

  def clean_error(error)
    return error.record.errors.full_messages.to_sentence if error.is_a?(ActiveRecord::RecordInvalid)
    return "This key changed. Reload before trying again." if error.is_a?(ActiveRecord::StaleObjectError)
    error.message.sub(/.*ERROR:\s*/, '').lines.first.to_s.first(300)
  end
end
