# GitHub-facing content only: descriptions and review state never enter this diff.
class CatalogPending
  def self.content(state)
    state.texts.each_with_object({}) do |text, result|
      next unless state.locales.include?(text.payload.locale)
      key = state.items.fetch(text.parent_id)
      file = [state.file_group(key).presence, text.payload.locale].compact.join('.') + '.yml'
      result[[file, state.path(key)]] = text.payload.value
    end
  end

  def self.files(files, project)
    yaml = CatalogYaml.new(files, project)
    yaml.values.each_with_object({}) do |(locale, values), result|
      values.each do |path, value|
        file = [yaml.root_groups[path.split('.').first].presence, locale].compact.join('.') + '.yml'
        result[[file, path]] = value
      end
    end
  end

  def self.diff(before, after)
    (before.keys | after.keys).sort.filter_map do |file, path|
      key = [file, path]
      next if before[key] == after[key]
      {file: file, path: path, before: before[key], after: after[key]}
    end
  end

  def self.outgoing(project)
    return [] unless project.linked?
    before = CatalogState.new(project)
    after = CatalogState.new(project, pending: true)
    # Include the user's unresolved proposal, without changing the live projection.
    project.catalog_drafts.where(conflict: true).includes(:payload).each do |draft|
      after.items[draft.catalog_node_id] = CatalogState::Item.new(id: draft.catalog_node_id, parent_id: draft.parent_id, payload: draft.payload, deleted: draft.deleted)
    end
    changes = diff(content(before), content(after))
    groups = after.keys.select { |key| key.parent_id.nil? }.map { |key| key.payload.file_group }.uniq.presence || ['']
    project.languages.active.where(pending_repository: true).each do |language|
      groups.each do |group|
        file = [group.presence, language.identifier].compact.join('.') + '.yml'
        next if changes.any? { |change| change[:file] == file }
        changes << {file: file, path: 'New language file', before: nil, after: "#{language.identifier}: {}"}
      end
    end
    changes
  end
end
