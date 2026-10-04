class CatalogReconcile
  # Reuse import validation for immutable Git versions without changing the live catalog.
  def self.preview(project, files, sha:)
    result = nil
    project.with_lock do
      Project.transaction(requires_new: true) do
        new(project, files, sha: sha).apply!
        result = yield CatalogState.new(project)
        raise ActiveRecord::Rollback
      end
    end
    result
  ensure
    project.reload
  end

  def initialize(project, files, sha:, author: nil, pr_check: false)
    @project, @yaml, @sha, @author, @pr_check = project, CatalogYaml.new(files, project), sha, author, pr_check
  end
  def apply!
    @project.with_lock do
      unless @yaml.values.key?(@project.source_locale)
        return if @pr_check && !@project.pr_check?(:source_keys)
        raise ArgumentError, "The source locale file is missing"
      end
      current = CatalogState.new(@project)
      @project.languages.each do |language|
        if @yaml.values.key?(language.identifier)
          language.update!(status: "active", pending_repository: false)
        elsif !language.pending_repository?
          language.update!(status: "archived")
        end
      end
      @yaml.values.each_key { |locale| @project.languages.find_or_create_by!(identifier: locale) }
      desired = CatalogState.new(@project, pr_check: @pr_check)
      by_path = current.keys.index_by { |key| current.path(key) }
      pending_state = CatalogState.new(@project, pending: true)
      pending_state.keys.each { |key| by_path[pending_state.path(key)] ||= key unless current.active?(current.items[key.id]) }
      source = @yaml.values.fetch(@project.source_locale)
      paths = (source.keys + source.keys.flat_map { |path| parts = path.split("."); (1...parts.size).map { |size| parts.first(size).join(".") } }).uniq.sort_by { |path| [path.count("."), path] }
      plural_paths = paths.select do |path|
        next false unless @project.pluralization?
        children = source.keys.filter_map { |candidate| candidate.delete_prefix("#{path}.") if candidate.start_with?("#{path}.") }
        children.include?("other") && children.all? { |name| CatalogKey::CATEGORIES.include?(name) }
      end.to_set
      plural_paths.each do |path|
        @project.languages.active.flat_map { |l| @project.plural_categories(l.identifier) }.uniq.each { |name| paths << "#{path}.#{name}" }
      end
      desired.items.each_value { |item| item.deleted = true }
      paths.uniq.sort_by { |path| [path.count("."), path] }.each do |path|
        parts = path.split("."); name = parts.pop
        kind = plural_paths.include?(path) ? "plural" : (source.key?(path) || plural_paths.include?(parts.join(".")) ? "scalar" : "branch")
        previous = by_path[path]
        payload = previous&.payload
        file_group = parts.empty? ? @yaml.root_groups.fetch(name, "") : ""
        payload = CatalogKey.create!(name: name, kind: kind, description: payload&.description.to_s, file_group: file_group) unless payload && payload.kind == kind && payload.file_group == file_group
        parent_id = by_path[parts.join(".")]&.id
        node = previous ? @project.catalog_nodes.find(previous.id) : @project.catalog_nodes.create!(payload: payload, parent_id: parent_id, deleted: true)
        item = CatalogState::Item.new(id: node.id, parent_id: parent_id, payload: payload, deleted: false)
        by_path[path] = desired.items[node.id] = item
      end
      @yaml.values.each do |locale, values|
        values.each do |path, value|
          key = by_path[path]
          next if @pr_check && !@project.pr_check?(:source_keys) && !(key && !key.deleted && key.payload.kind == "scalar" && paths.include?(path))
          raise ArgumentError, "#{locale}: #{path} is not a source scalar key" unless key && !key.deleted && key.payload.kind == "scalar" && paths.include?(path)
          old = current.translation(key.id, locale) || pending_state.translation(key.id, locale)
          payload = old&.payload&.value == value ? old.payload : CatalogText.create!(locale: locale, value: value)
          node = old ? @project.catalog_nodes.find(old.id) : @project.catalog_nodes.create!(payload: payload, parent_id: key.id, deleted: true)
          desired.items[node.id] = CatalogState::Item.new(id: node.id, parent_id: key.id, payload: payload, deleted: false)
        end
      end
      # Archiving a locale keeps its accepted values for later reactivation.
      current.texts.each { |item| desired.items[item.id] = item if !@yaml.values.key?(item.payload.locale) && desired.active?(desired.items[item.parent_id]) }
      errors = desired.structure_errors + desired.invalid_groups.flat_map { |(id, locale), messages| messages.map { |message| "#{locale}: #{desired.path(desired.items.fetch(id))}: #{message}" } }
      raise ArgumentError, errors.uniq.join("; ") if errors.any?
      return if @pr_check
      # Compare semantic values, not immutable payload IDs, during three-way reconciliation.
      @project.catalog_drafts.includes(:payload, catalog_node: :payload).each do |draft|
        incoming = desired.items[draft.catalog_node_id]
        next unless incoming
        base = CatalogState::Item.new(id: draft.catalog_node_id, parent_id: draft.base_parent_id, payload: draft.base_type.constantize.find(draft.base_id), deleted: draft.base_deleted)
        pending = CatalogState::Item.new(id: draft.catalog_node_id, parent_id: draft.parent_id, payload: draft.payload, deleted: draft.deleted)
        if incoming.signature == pending.signature
          draft.destroy!
        elsif incoming.signature != base.signature
          draft.update!(conflict: true)
        elsif !pending.deleted && pending.parent_id && !desired.active?(desired.items[pending.parent_id]) && !@project.catalog_drafts.where(catalog_node_id: pending.parent_id, deleted: false).exists?
          draft.update!(conflict: true)
        end
      end
      CatalogWriter.new(@project).accept!(desired, summary: "Synced #{@sha.first(10)}", origin: "github", commit_sha: @sha, github_author: @author)
      @project.update!(git_sha: @sha, sync_error: nil, revision: @project.revision + 1)
      @project.catalog_git_revisions.find_or_initialize_by(commit_sha: @sha).update!(status: "accepted", error: nil)
    end
  rescue ArgumentError, ActiveRecord::RecordInvalid => error
    unless @pr_check
      @project.reload.update!(sync_error: error.message)
      @project.catalog_git_revisions.find_or_initialize_by(commit_sha: @sha).update!(status: "failed", error: error.message)
    end
    raise
  end
end
