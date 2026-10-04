class CatalogWriter
  attr_reader :project, :actor
  def initialize(project, actor: nil)
    @project, @actor = project, actor
  end

  def edit(expected:, summary: "Edited catalog", origin: "manual")
    raise ArgumentError, "Synchronization is in progress. Please wait before editing." if project.reload.sync_busy?
    project.with_lock do
      raise ArgumentError, "Repair Git synchronization before editing" unless project.writable?
      raise ActiveRecord::StaleObjectError.new(project, "edit") unless expected.to_s == project.revision.to_s
      @state = CatalogState.new(project, pending: true)
      yield self
      prune!
      raise ArgumentError, @state.structure_errors.join("; ") if @state.structure_errors.any?
      accept!(@state.publication, summary: summary, origin: origin) unless project.linked?
      project.increment!(:revision)
      project.catalog_drafts.reset
    end
  end

  def stage(item)
    node = project.catalog_nodes.find(item.id)
    draft = project.catalog_drafts.find_or_initialize_by(catalog_node: node)
    if draft.new_record?
      draft.assign_attributes(base_type: node.payload_type, base_id: node.payload_id, base_parent_id: node.parent_id, base_deleted: node.deleted)
    else
      raise ArgumentError, "Resolve the conflict before editing this value" if draft.conflict?
    end
    project.catalog_draft_edits.create!(catalog_node: node, actor: actor, previous_payload_type: draft.payload_type || node.payload_type, previous_payload_id: draft.payload_id || node.payload_id, previous_parent_id: draft.persisted? ? draft.parent_id : node.parent_id, previous_deleted: draft.persisted? ? draft.deleted : node.deleted, created_at: Time.current)
    draft.update!(payload: item.payload, parent_id: item.parent_id, deleted: item.deleted, actor: actor)
    @state.items[item.id] = item
    @state.changed!
  end

  def create_item(payload, parent_id)
    node = project.catalog_nodes.create!(payload: payload, parent_id: parent_id, deleted: true)
    item = CatalogState::Item.new(id: node.id, parent_id: parent_id, payload: payload, deleted: false)
    stage(item)
    item
  end

  def add_key(path, kind: "scalar", description: "", file_group: "")
    raise ArgumentError, "Pluralization is disabled for this project" if kind == "plural" && !project.pluralization?
    parts = path.to_s.split(".", -1)
    raise ArgumentError, "Enter a dotted path without empty segments" if parts.empty? || parts.any?(&:blank?)
    parent = nil
    parts.each_with_index do |segment, index|
      if parent && @state.plural?(parent) && CatalogKey::CATEGORIES.include?(segment)
        raise ArgumentError, "Plural forms are managed automatically for the project's languages"
      end
      found = @state.keys.find { |k| k.parent_id == parent&.id && k.payload.name == segment }
      raise ArgumentError, "This key already exists" if found && index == parts.length - 1
      if found
        raise ArgumentError, "Move the scalar into a child before adding nested keys" if found.payload.kind == "scalar"
        parent = found
      else
        parent = create_item(CatalogKey.create!(name: segment, kind: index == parts.length - 1 ? kind : "branch", description: index == parts.length - 1 ? description : "", file_group: index.zero? ? file_group : ""), parent&.id)
      end
    end
    ensure_categories(parent) if kind == "plural"
    parent
  end

  def change_key(id, name: nil, path: nil, kind:, description: "", file_group: nil)
    raise ArgumentError, "Pluralization is disabled for this project" if kind == "plural" && !project.pluralization?
    item = @state.items.fetch(id.to_i)
    raise ArgumentError, "Key not found" unless item.key? && @state.active?(item)
    name = item.payload.name if path
    raise ArgumentError, "Move this scalar into a child first" if item.payload.kind == "scalar" && kind != "scalar"
    if @state.plural?(item) && kind == "branch"
      @state.children(item.id).select(&:key?).each { |child| remove(child.id) if @state.children(child.id).none?(&:text?) }
    end
    raise ArgumentError, "File groups can only be assigned to root keys" if item.parent_id && file_group.present?
    item.payload = CatalogKey.create!(name: name, kind: kind, description: description, file_group: item.parent_id ? "" : (file_group || item.payload.file_group))
    stage(item)
    ensure_categories(item) if kind == "plural"
    move(id, path) if path && path != @state.path(item)
  end

  def ensure_categories(item)
    project.languages.active.flat_map { |l| project.plural_categories(l.identifier) }.uniq.each do |name|
      next if @state.children(item.id).any? { |child| child.key? && child.payload.name == name }
      create_item(CatalogKey.create!(name: name, kind: "scalar"), item.id)
    end
  end
  def refresh_categories
    @state.keys.select { |key| key.payload.kind == "plural" }.each { |key| ensure_categories(key) }
  end

  def translate(id, locale, value)
    key = @state.items.fetch(id.to_i)
    raise ArgumentError, "Only active scalar keys carry translations" unless @state.active?(key) && key.key? && key.payload.kind == "scalar"
    raise ArgumentError, "Language is not supported" unless project.languages.active.exists?(identifier: locale)
    raise ArgumentError, "This plural form is not used by #{CatalogLocale.name(locale)}" unless @state.translatable?(key, locale)
    old = @state.translation(key.id, locale)
    if value.empty?
      remove(old.id) if old
    elsif old
      unless old.payload.value == value
        old.payload = CatalogText.create!(locale: locale, value: value)
        stage(old)
      end
    else
      create_item(CatalogText.create!(locale: locale, value: value), key.id)
    end
    if value.present? && locale != project.source_locale
      translation = @state.translation(key.id, locale)
      CatalogReview.find_or_initialize_by(catalog_node_id: translation.id).update!(actor: actor, source_digest: @state.source_digest(key), translation_payload_id: translation.payload.id)
    end
  end

  def remove(id)
    item = @state.items.fetch(id.to_i)
    @state.children(item.id).each { |child| remove(child.id) }
    item.deleted = true
    stage(item)
  end

  def move(id, destination)
    item = @state.items.fetch(id.to_i)
    raise ArgumentError, "Key not found" unless item.key? && @state.active?(item)
    raise ArgumentError, "Enter a dotted path without empty segments" if destination.split(".", -1).any?(&:blank?) || destination.blank?
    old_path = @state.path(item)
    if item.payload.kind == "scalar" && destination.start_with?("#{old_path}.")
      texts = @state.children(item.id).select(&:text?)
      item.payload = CatalogKey.create!(name: item.payload.name, kind: "branch", description: item.payload.description, file_group: item.payload.file_group)
      stage(item)
      child = add_key(destination, description: item.payload.description)
      texts.each { |text| text.parent_id = child.id; stage(text) }
    else
      raise ArgumentError, "Cannot move a key inside itself" if destination.start_with?("#{old_path}.")
      parts = destination.split("."); name = parts.pop
      parent = parts.empty? ? nil : @state.keys.find { |k| @state.path(k) == parts.join(".") }
      parent ||= add_key(parts.join('.'), kind: "branch") if parts.any?
      raise ArgumentError, "Destination must be a branch" if parent && parent.payload.kind == "scalar"
      raise ArgumentError, "Plural forms are managed automatically for the project's languages" if parent && @state.plural?(parent) && CatalogKey::CATEGORIES.include?(name)
      cursor = parent
      while cursor
        raise ArgumentError, "Cannot move a key inside itself" if cursor.id == item.id
        cursor = @state.items[cursor.parent_id]
      end
      file_group = parent ? "" : @state.file_group(item)
      item.parent_id = parent&.id
      item.payload = CatalogKey.create!(name: name, kind: item.payload.kind, description: item.payload.description, file_group: file_group)
      stage(item)
    end
  end

  def prune!
    loop do
      empty = @state.keys.select { |key| key.payload.kind == "branch" && @state.children(key.id).empty? }
      break if empty.empty?
      empty.each { |key| remove(key.id) }
    end
  end

  def accept!(desired, summary:, origin: "manual", commit_sha: nil, github_author: nil)
    current = CatalogState.new(project)
    changes = desired.items.values.select { |item| current.items[item.id]&.signature != item.signature }
    if changes.empty?
      project.catalog_drafts.where(conflict: false).includes(:payload).each do |draft|
        item = CatalogState::Item.new(id: draft.catalog_node_id, parent_id: draft.parent_id, payload: draft.payload, deleted: draft.deleted)
        draft.destroy! if current.items[item.id]&.signature == item.signature
      end
      return nil
    end
    change = project.catalog_change_sets.create!(actor: actor, summary: summary, origin: origin, commit_sha: commit_sha, github_author: github_author)
    sequence = 0
    changes.each do |item|
      node = project.catalog_nodes.find(item.id)
      existed = node.catalog_events.exists?
      record = lambda do |action, previous = {}|
        sequence += 1
        change.catalog_events.create!(catalog_node: node, sequence: sequence, action: action, created_at: Time.current, **previous)
      end
      record.call("payload_replaced", previous_payload_type: node.payload_type, previous_payload_id: node.payload_id) if node.payload_type != item.payload.class.name || node.payload_id != item.payload.id
      record.call("node_moved", previous_parent_id: node.parent_id) if node.parent_id != item.parent_id
      record.call(item.deleted ? "node_deleted" : (existed ? "node_reactivated" : "node_created")) if node.deleted != item.deleted
      node.update!(payload: item.payload, parent_id: item.parent_id, deleted: item.deleted)
      draft = project.catalog_drafts.find_by(catalog_node: node)
      draft.destroy! if draft && !draft.conflict? && [draft.parent_id, draft.payload_type, draft.payload_id, draft.deleted] == [node.parent_id, node.payload_type, node.payload_id, node.deleted]
    end
    change
  end

  def restore(event_position, expected:)
    edit(expected: expected, summary: "Restored catalog", origin: "restore") do
      historical = CatalogState.new(project, at: event_position)
      historical.items.each_value { |item| stage(item) unless @state.items[item.id].signature == item.signature }
    end
  end

  def resolve(id, choice:, expected:)
    project.with_lock do
      raise ArgumentError, "Repair Git synchronization before resolving conflicts" unless project.writable?
      raise ActiveRecord::StaleObjectError.new(project, "resolve") unless expected.to_s == project.revision.to_s
      draft = project.catalog_drafts.find(id)
      project.catalog_draft_edits.create!(catalog_node: draft.catalog_node, actor: actor, previous_payload_type: draft.payload_type, previous_payload_id: draft.payload_id, previous_parent_id: draft.parent_id, previous_deleted: draft.deleted, created_at: Time.current)
      if choice == "github"
        draft.destroy!
      else
        node = draft.catalog_node
        draft.update!(conflict: false, base_type: node.payload_type, base_id: node.payload_id, base_parent_id: node.parent_id, base_deleted: node.deleted)
      end
      project.increment!(:revision)
    end
  end

  def restore_draft(revision, expected:)
    edit(expected: expected, summary: "Reapplied earlier draft") do
      stage(CatalogState::Item.new(id: revision.catalog_node_id, parent_id: revision.previous_parent_id, payload: revision.previous_payload_type.constantize.find(revision.previous_payload_id), deleted: revision.previous_deleted))
    end
  end
end
