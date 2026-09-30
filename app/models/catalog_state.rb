# One reusable projection for the editor, validation, history, diff and export.
class CatalogState
  Item = Struct.new(:id, :parent_id, :payload, :deleted, keyword_init: true) do
    def key? = payload.is_a?(CatalogKey)
    def text? = payload.is_a?(CatalogText)
    def signature = [parent_id, payload.class.name, payload.attributes.except("id"), deleted]
  end
  attr_reader :project, :items, :locales

  def initialize(project, pending: false, at: nil, items: nil, locales: nil)
    @project = project
    @locales = locales || project.languages.active.pluck(:identifier)
    @items = items || project.catalog_nodes.includes(:payload).to_h { |n| [n.id, Item.new(id: n.id, parent_id: n.parent_id, payload: n.payload, deleted: n.deleted)] }
    if at
      project.catalog_events.where("catalog_events.id > ?", at).reorder(id: :desc).each { |event| undo(event) }
    elsif pending
      project.catalog_drafts.where(conflict: false).includes(:payload).each { |d| @items[d.catalog_node_id] = Item.new(id: d.catalog_node_id, parent_id: d.parent_id, payload: d.payload, deleted: d.deleted) }
    end
  end

  def undo(event)
    item = items.fetch(event.catalog_node_id)
    case event.action
    when "node_created", "node_reactivated" then item.deleted = true
    when "node_deleted" then item.deleted = false
    when "node_moved" then item.parent_id = event.previous_parent_id
    when "payload_replaced" then item.payload = event.previous_payload_type.constantize.find(event.previous_payload_id)
    end
  end

  def active?(item, seen = Set.new)
    return false if !item || item.deleted || seen.include?(item.id)
    seen.add(item.id)
    !item.parent_id || active?(items[item.parent_id], seen)
  end

  def changed!
    @keys = @texts = @children = @translations = nil
  end
  def keys = @keys ||= items.values.select { |i| i.key? && active?(i) }
  def texts = @texts ||= items.values.select { |i| i.text? && active?(i) }
  def children(id) = (@children ||= items.values.group_by(&:parent_id)).fetch(id, []).select { |i| active?(i) }
  def path(item)
    parts = []; seen = Set.new
    while item
      raise ArgumentError, "Key cycle" unless seen.add?(item.id)
      parts.unshift(item.payload.name) if item.key?
      item = items[item.parent_id]
    end
    parts.join(".")
  end
  def translation(key_id, locale) = (@translations ||= texts.index_by { |i| [i.parent_id, i.payload.locale] })[[key_id, locale]]
  def plural_parent(key)
    parent = items[key.parent_id]
    parent if parent&.key? && parent.payload.kind == "plural"
  end
  def translatable?(key, locale)
    key.payload.kind == "scalar" && (!plural_parent(key) || CatalogLocale.categories(locale).include?(key.payload.name))
  end
  def source(key)
    translation(key.id, project.source_locale) || (plural_parent(key) && children(key.parent_id).find { |i| i.key? && i.payload.name == "other" }.then { |other| translation(other.id, project.source_locale) if other })
  end
  def source_digest(key) = Digest::SHA256.hexdigest(source(key)&.payload&.id.to_s)
  def placeholders(text) = text.scan(/(?<!%)%\{([^}]+)\}/).flatten.to_set

  def text_errors(key, locale)
    value = translation(key.id, locale)
    return [] unless value
    tokens = placeholders(value.payload.value)
    return ["Translate the source language first"] if locale != project.source_locale && !source(key)
    if plural_parent(key)
      %w[other few many].include?(key.payload.name) && !tokens.include?("count") ? ["This plural form requires %{count}"] : []
    else
      errors = tokens.include?("count") ? ["%{count} is only allowed in plural translations"] : []
      expected = placeholders(source(key)&.payload&.value.to_s)
      errors << "Placeholders must match the source: #{expected.to_a.join(', ')}" if locale != project.source_locale && expected != tokens
      errors
    end
  end
  def warnings(key, locale)
    parent = plural_parent(key)
    return [] unless parent && (value = translation(key.id, locale))
    expected = children(parent.id).select(&:key?).flat_map { |form| placeholders(translation(form.id, project.source_locale)&.payload&.value.to_s).to_a }.to_set - ["count"]
    actual = placeholders(value.payload.value) - ["count"]
    expected == actual ? [] : ["Source placeholders differ: #{expected.to_a.join(', ')}"]
  end

  def structure_errors
    errors = []
    keys.group_by { |i| [i.parent_id, i.payload.name] }.each { |_, group| errors << "Duplicate key #{path(group.first)}" if group.size > 1 }
    keys.each do |key|
      descendants = children(key.id)
      errors << "#{path(key)}: scalar cannot contain keys" if key.payload.kind == "scalar" && descendants.any?(&:key?)
      errors << "#{path(key)}: branches cannot contain translations" if key.payload.kind != "scalar" && descendants.any?(&:text?)
      if key.payload.kind == "plural"
        errors << "#{path(key)}: invalid plural child" if descendants.any? { |i| !i.key? || i.payload.kind != "scalar" || !CatalogKey::CATEGORIES.include?(i.payload.name) }
      end
    end
    texts.group_by { |i| [i.parent_id, i.payload.locale] }.each { |_, group| errors << "Duplicate locale translation" if group.size > 1 }
    errors
  end

  def plural_group_errors(key, locale)
    forms = children(key.id).select(&:key?).index_by { |item| item.payload.name }
    return [] unless forms.values.any? { |form| translation(form.id, locale) }
    missing = CatalogLocale.categories(locale).reject { |name| forms[name] && translation(forms[name].id, locale) }
    missing.any? ? ["Missing plural forms: #{missing.join(', ')}"] : []
  end

  def invalid_groups
    errors = {}
    keys.each do |key|
      if key.payload.kind == "plural"
        forms = children(key.id).select(&:key?).index_by { |i| i.payload.name }
        locales.each do |locale|
          next unless forms.values.any? { |form| translation(form.id, locale) }
          messages = plural_group_errors(key, locale)
          messages += forms.values.flat_map { |form| text_errors(form, locale) }
          errors[[key.id, locale]] = messages if messages.any?
        end
      elsif key.payload.kind == "scalar" && !plural_parent(key)
        locales.each do |locale|
          messages = text_errors(key, locale)
          errors[[key.id, locale]] = messages if messages.any?
        end
      end
    end
    errors
  end

  def group_for(item)
    key = item.text? ? items.fetch(item.parent_id) : item
    [(plural_parent(key) || key).id, item.text? ? item.payload.locale : nil]
  end

  def publication
    result = CatalogState.new(project)
    errors = invalid_groups
    # Draft source changes and dependent translations are evaluated as one group.
    blocked = errors.keys.to_set
    errors.each_key { |key_id, locale| project.languages.active.each { |l| blocked.add([key_id, l.identifier]) } if locale == project.source_locale }
    source_groups = project.catalog_drafts.includes(:payload).filter_map do |draft|
      item = items[draft.catalog_node_id]
      group_for(item).first if item&.text? && item.payload.locale == project.source_locale
    end
    errors.each_key { |key_id, _| project.languages.active.each { |l| blocked.add([key_id, l.identifier]) } if source_groups.include?(key_id) }
    blocked_nodes = Set.new
    project.catalog_drafts.where(payload_type: "CatalogKey").each do |draft|
      descendants = items.values.select do |item|
        cursor = item
        seen = Set.new
        while cursor && seen.add?(cursor.id)
          break if cursor.id == draft.catalog_node_id
          cursor = items[cursor.parent_id]
        end
        cursor&.id == draft.catalog_node_id
      end.map(&:id)
      blocked_nodes.merge(descendants) if errors.keys.any? { |id, _| descendants.include?(id) }
    end
    project.catalog_drafts.where(conflict: false).includes(:payload).each do |draft|
      item = items.fetch(draft.catalog_node_id)
      next if blocked_nodes.include?(item.id)
      group = group_for(item)
      ancestors = []; parent = items[item.parent_id]
      while parent
        ancestors << parent.id
        parent = items[parent.parent_id]
      end
      next if project.catalog_drafts.where(conflict: true, catalog_node_id: ancestors).exists?
      next if blocked.include?(group) || (item.key? && blocked.any? { |id, _| id == group.first })
      result.items[item.id] = item.dup
    end
    # A structural conflict can invalidate dependent edits; publish only a valid projection.
    raise ArgumentError, result.structure_errors.join("; ") if result.structure_errors.any?
    result
  end
end
