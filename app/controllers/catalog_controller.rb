class CatalogController < ApplicationController
  layout "settings"
  allow_unauthenticated_access only: [:translations, :export, :sync_status]
  before_action :set_project
  after_action :verify_authorized

  def translations
    authorize @project, :show?
    @state = CatalogState.new(@project, pending: current_user && policy(@project).pending?)
    @languages = @project.languages.active.order(:name).to_a
    @locale = params[:locale].presence_in(@languages.map(&:identifier)) || (@languages.map(&:identifier) - [@project.source_locale]).first || @project.source_locale
    @query = params[:q].to_s.first(200)
    @status = params[:status].presence_in(%w[all incomplete review]) || "all"
    @kind = params[:kind].presence_in(%w[all scalar plural]) || "all"
    @sort = params[:sort].presence_in(%w[path oldest newest]) || "path"
    @file_group_options = [{id: ":default", label: "Default"}] + @state.keys.select { |key| key.parent_id.nil? }.map { |key| key.payload.file_group }.reject(&:blank?).uniq.sort.map { |group| {id: group, label: group} }
    @file_groups = Array(params[:file_groups]) & @file_group_options.map { |option| option[:id] }
    @filters_active = @query.present? || @status != "all" || @kind != "all" || @sort != "path" || Array(params[:file_groups]).any?
    @flat_results = @query.present? || @status != "all" || @kind != "all" || @sort != "path"
    @reviews = CatalogReview.where(catalog_node_id: @state.texts.map(&:id)).index_by(&:catalog_node_id)
    @invalid = @state.invalid_groups
    @drafts = current_user && policy(@project).pending? ? @project.catalog_drafts.index_by(&:catalog_node_id) : {}
    @all_keys = @state.keys.sort_by do |key|
      parts = @state.path(key).split(".")
      parts[-1] = format("%02d", CatalogKey::CATEGORIES.index(key.payload.name)) if @state.plural_parent(key)
      parts
    end
    @all_keys.select! { |key| @state.path(key).include?(@query) || @state.children(key.id).any? { |i| i.text? && i.payload.value.downcase.include?(@query.downcase) } } if @query.present?
    @all_keys.select! { |key| @file_groups.include?(@state.file_group(key).presence || ":default") } if @file_groups.any?
    @all_keys.select! do |key|
      parent = @state.plural_parent(key)
      next false if parent && ![@project.source_locale, @locale].flat_map { |locale| @project.plural_categories(locale) }.include?(key.payload.name)
      next false if @kind == "plural" && !parent && !@state.plural?(key)
      next false if @kind == "scalar" && (parent || key.payload.kind != "scalar")
      value = @state.translation(key.id, @locale)
      review = value && @reviews[value.id]
      case @status
      when "incomplete" then key.payload.kind == "scalar" && (!value || @invalid.key?([(parent || key).id, @locale]))
      when "review" then @state.translatable?(key, @locale) && (
        @invalid.key?([(parent || key).id, @locale]) || @state.warnings(key, @locale).any? || (value && @drafts[value.id]&.conflict?) ||
        (@locale != @project.source_locale && value && (!review || review.source_digest != @state.source_digest(key))))
      else true
      end
    end
    if @sort != "path"
      edited = @project.catalog_events.group(:catalog_node_id).maximum(:created_at)
      @project.catalog_draft_edits.group(:catalog_node_id).maximum(:created_at).each { |id, time| edited[id] = [edited[id], time].compact.max }
      @all_keys.sort_by! do |key|
        last_edit = ([key.id] + @state.children(key.id).select(&:text?).map(&:id)).filter_map { |id| edited[id] }.max&.to_f || 0
        [@sort == "oldest" ? last_edit : -last_edit, @state.path(key)]
      end
    end
    @page = [params[:page].to_i, 1].max
    @keys = @all_keys.slice((@page - 1) * 40, 40) || []
  end

  def restore_draft
    authorize @project, :pending?
    revision = @project.catalog_draft_edits.find(params[:draft_edit_id])
    payload = revision.previous_payload_type.constantize.find(revision.previous_payload_id)
    if payload.is_a?(CatalogText)
      raise Pundit::NotAuthorizedError unless policy(@project).edit_locale?(payload.locale)
    else
      authorize @project, :update?
    end
    CatalogWriter.new(@project, actor: current_user).restore_draft(revision, expected: params[:revision])
    render json: {location: pending_project_path(@project)}
  rescue ArgumentError, ActiveRecord::StaleObjectError, ActiveRecord::RecordInvalid => error
    render json: {error: error.message}, status: :unprocessable_entity
  end

  def pending
    authorize @project, :pending?
    @state = CatalogState.new(@project, pending: true)
    @accepted = CatalogState.new(@project)
    @page = [params[:page].to_i, 1].max
    @drafts = @project.catalog_drafts.includes(:actor, :payload, catalog_node: :payload).order(:id).offset((@page - 1) * 40).limit(40)
    @invalid = @state.invalid_groups
  end

  def history
    authorize @project, :history?
    @page = [params[:page].to_i, 1].max
    @query = params[:q].to_s.first(200)
    @locales = Array(params[:locales]) & CatalogLocale::DATA.keys
    @types = Array(params[:types]) & %w[CatalogKey CatalogText]
    @actors = Array(params[:actors]).select { |id| id.match?(/\A[0-9a-f-]{36}\z/) }
    changes = @project.catalog_change_sets.where(status: "accepted")
    @actor_options = User.where(id: changes.select(:actor_id)).order(:name).map { |user| {id: user.id, label: user.name.presence || "Unnamed user"} }
    changes = changes.where(actor_id: @actors) if @actors.any?
    nodes = @project.catalog_nodes
    nodes = nodes.where(payload_type: @types) if @types.any?
    if @locales.any?
      nodes = nodes.where(payload_type: "CatalogKey").or(nodes.where(payload_type: "CatalogText", payload_id: CatalogText.where(locale: @locales).select(:id)))
    end
    if @query.present?
      state = CatalogState.new(@project)
      ids = state.items.values.select { |item| state.path(item).include?(@query) }.map(&:id)
      nodes = nodes.where(id: ids)
    end
    changes = changes.where(id: @project.catalog_events.where(catalog_node_id: nodes.select(:id)).select(:catalog_change_set_id))
    @pages = [(changes.count / 20.0).ceil, 1].max
    @page = [@page, @pages].min
    @changes = changes.includes(:actor).order(id: :desc).offset((@page-1)*20).limit(20)
  end

  def history_events
    authorize @project, :history?
    @change = @project.catalog_change_sets.find(params[:change_set_id])
    @offset = [params[:offset].to_i, 0].max
    @limit = @offset.zero? ? 10 : 20
    render :history_events, formats: [:turbo_stream]
  end

  def change
    authorize @project, :show?
    writer = CatalogWriter.new(@project, actor: current_user)
    operation = params.require(:operation)
    if operation == "translate"
      raise Pundit::NotAuthorizedError unless policy(@project).edit_locale?(params[:locale])
    else
      authorize @project, :update?
    end
    writer.edit(expected: params.require(:revision), summary: operation.humanize) do |edit|
      case operation
      when "add" then edit.add_key(params[:path], kind: params[:kind].presence || "scalar", description: params[:description].to_s, file_group: params[:file_group].to_s)
      when "translate" then edit.translate(params[:node_id], params[:locale], params[:value].to_s)
      when "update" then edit.change_key(params[:node_id], name: params[:name], path: params[:path], kind: params[:kind], description: params[:description].to_s, file_group: params[:file_group])
      when "delete" then edit.remove(params[:node_id])
      else raise ArgumentError, "Unknown change"
      end
    end
    if operation == "translate" && params[:inline] == "1"
      @state = CatalogState.new(@project, pending: true)
      key = @state.items.fetch(params[:node_id].to_i)
      value = @state.translation(key.id, params[:locale])&.payload&.value.to_s
      @drafts = @project.catalog_drafts.index_by(&:catalog_node_id)
      @reviews = CatalogReview.where(catalog_node_id: @state.texts.map(&:id)).index_by(&:catalog_node_id)
      @invalid = @state.invalid_groups
      parent = @state.plural_parent(key)
      keys = parent ? [parent] + @state.children(parent.id).select(&:key?) : [key]
      statuses = keys.product(@project.languages.active.pluck(:identifier)).map do |item, locale|
        {id: "#{item.id}-#{locale}", html: render_to_string(partial: "cell_status", formats: [:html], locals: {key: item, locale: locale})}
      end
      modals = @project.languages.active.pluck(:identifier).select { |locale| @state.translatable?(key, locale) && policy(@project).edit_locale?(locale) }.map do |locale|
        {id: "catalog-text-#{key.id}-#{locale}", html: render_to_string(partial: "translation_modal", formats: [:html], locals: {key: key, locale: locale})}
      end
      render json: {revision: @project.reload.revision, value: value, html: helpers.catalog_text(value), statuses: statuses, modals: modals}
    else
      render json: {location: translations_project_path(@project, locale: params[:locale])}
    end
  rescue ActiveRecord::StaleObjectError
    render json: {error: "The catalog changed while you were editing. Your text is preserved; reload the latest catalog before retrying."}, status: :conflict
  rescue ActiveRecord::RecordInvalid, ArgumentError, KeyError => error
    render json: {error: error.message}, status: :unprocessable_entity
  end

  def review
    authorize @project, :show?
    @project.with_lock do
      raise ArgumentError, "Repair Git synchronization first" unless @project.writable?
      state = CatalogState.new(@project, pending: true)
      key = state.items.fetch(params[:node_id].to_i)
      raise Pundit::NotAuthorizedError unless policy(@project).edit_locale?(params[:locale])
      value = state.translation(key.id, params[:locale]) || raise(ArgumentError, "Translate this key first")
      raise ArgumentError, "The source changed. Review its latest text first." unless state.source_digest(key) == params[:source_digest]
      raise ArgumentError, "The translation changed. Review its latest text first." unless value.payload.id.to_s == params[:translation_payload_id]
      CatalogReview.find_or_initialize_by(catalog_node_id: value.id).update!(actor: current_user, source_digest: params[:source_digest], translation_payload_id: value.payload.id)
    end
    render json: {location: translations_project_path(@project, locale: params[:locale])}
  rescue ArgumentError, KeyError => error
    render json: {error: error.message}, status: :conflict
  end

  def restore
    authorize @project, :update?
    change = @project.catalog_change_sets.find(params[:change_set_id])
    CatalogWriter.new(@project, actor: current_user).restore(change.catalog_events.maximum(:id), expected: params[:revision])
    render json: {location: @project.linked? ? pending_project_path(@project) : history_project_path(@project)}
  rescue ArgumentError, ActiveRecord::StaleObjectError => error
    render json: {error: error.message}, status: :unprocessable_entity
  end

  def resolve
    authorize @project, :update?
    raise ArgumentError, "Choose a side" unless %w[github lattrix].include?(params[:choice])
    CatalogWriter.new(@project, actor: current_user).resolve(params[:draft_id], choice: params[:choice], expected: params[:revision])
    render json: {location: pending_project_path(@project)}
  rescue ArgumentError, ActiveRecord::StaleObjectError => error
    render json: {error: error.message}, status: :unprocessable_entity
  end

  def export
    authorize @project, :show?
    raise ArgumentError, "Export is paused until Git synchronization is repaired" unless @project.writable?
    if params[:tag_id].present?
      tag = @project.catalog_tags.find(params[:tag_id])
      raise ArgumentError, "Reconnect the repository to export Git versions" unless @project.linked?
      commit, files = CatalogGithub.new(@project).snapshot(tag.commit_sha)
      data, filename, type = CatalogReconcile.preview(@project, files, sha: commit.fetch("sha")) do |state|
        CatalogExport.new(@project, state: state).download(params[:format_name])
      end
      send_data data, filename: filename, type: type
      return
    end
    position = @project.catalog_change_sets.find(params[:change_set_id]).catalog_events.maximum(:id) if params[:change_set_id].present?
    ApplicationRecord.transaction(isolation: :repeatable_read) do
      data, filename, type = CatalogExport.new(@project, state: CatalogState.new(@project, at: position)).download(params[:format_name])
      send_data data, filename: filename, type: type
    end
  rescue ArgumentError, CatalogGithub::Error => error
    if request.headers['Accept'].to_s.include?('application/octet-stream')
      render json: {error: error.message}, status: :unprocessable_entity
    else
      redirect_to translations_project_path(@project), alert: error.message
    end
  end

  def sync
    authorize @project, :update?
    raise ArgumentError, "Connect a repository first" unless @project.linked?
    unless @project.sync_busy?
      @project.with_lock do
        CatalogSyncJob.perform_later(@project.id, publish: true, initial: @project.git_sha.nil?) unless @project.sync_busy?
      end
    end
    render json: {location: translations_project_path(@project)}, status: :accepted
  rescue ArgumentError => error
    render json: {error: error.message}, status: :unprocessable_entity
  end

  def sync_status
    authorize @project, :show?
    response.headers["Cache-Control"] = "no-store"
    render json: @project.sync_feedback
  end

  def source_locale
    authorize @project, :update?
    @project.change_source_locale!(params[:source_locale], expected: params[:revision])
    render json: {location: settings_project_path(@project)}
  rescue ArgumentError, ActiveRecord::StaleObjectError, ActiveRecord::RecordInvalid => error
    render json: {error: error.message}, status: :unprocessable_entity
  end

  def connect
    authorize @project, :update?
    raise ArgumentError, "Wait for synchronization to finish before changing the connection" if @project.sync_busy?
    @project.with_lock do
    if params[:disconnect] == "1"
      @project.update!(repository: nil, installation_id: nil, git_sha: nil, git_branch: nil, pull_request_number: nil, sync_error: nil, sync_status: "idle", sync_job_id: nil, sync_message: nil)
      flash[:notice] = "Repository disconnected."
    else
      raise ArgumentError, "Configure the GitHub App credentials before connecting a repository" unless CatalogGithub.configured?
      previous = [@project.repository, @project.installation_id, @project.git_branch, @project.locale_directory]
      @project.assign_attributes(params.permit(:repository, :installation_id, :git_branch, :locale_directory))
      raise ActiveRecord::RecordInvalid, @project unless @project.valid?
      # The installation grants repository access; personal login providers are unrelated.
      CatalogGithub.new(@project).repository
      @project.assign_attributes(git_sha: nil, pull_request_number: nil, sync_error: nil) if previous != [@project.repository, @project.installation_id, @project.git_branch, @project.locale_directory]
      @project.save!
      CatalogSyncJob.perform_later(@project.id, initial: true)
      flash[:notice] = "Repository connected. Synchronization has been queued."
    end
    end
    render json: {location: settings_project_path(@project)}
  rescue ActiveRecord::RecordInvalid, ArgumentError, CatalogGithub::Error => error
    render json: {error: error.message}, status: :unprocessable_entity
  end

  private
  def set_project
    @project = policy_scope(Project).find_by!(slug: params[:id])
  end
end
