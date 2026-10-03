module CatalogHelper
  def catalog_text(value)
    return "—" if value.nil?
    safe_join(value.split(/((?<!%)%\{[^}]+\})/).map do |part|
      if part.match?(/\A%\{[^}]+\}\z/)
        content_tag(:span, part, class: part == "%{count}" ? "catalog-count" : "translation-wildcard")
      else
        part
      end
    end)
  end
  def catalog_form(url, **options, &block)
    form_with(url: url, data: {catalog_form: true, turbo: false}, **options, &block)
  end
  def catalog_kind_options = CatalogKey::KINDS.map { |kind| {id: kind, label: kind.capitalize} }
  def catalog_actions
    options = [{id: 'export', label: 'Export', icon: 'download', disabled: !@project.writable?}, {id: 'import', label: 'Import (coming soon)', icon: 'upload', disabled: true}]
    if @project.linked? && policy(@project).update?
      options += [{id: 'sync', label: 'Sync', icon: 'refresh-cw', disabled: @project.sync_busy?}, {id: 'publish', label: 'Generate PR', icon: 'code', disabled: @project.sync_busy?}]
    end
    options
  end

  def catalog_event_label(event, item, origin)
    noun = item.text? ? "translation for" : "translation key"
    verb = case event.action
    when "node_created", "node_reactivated" then origin == "restore" ? "Restored" : "Added"
    when "node_deleted" then origin == "restore" ? "Reverted creation of" : "Deleted"
    when "node_moved" then origin == "restore" ? "Reverted move of" : "Moved"
    else origin == "restore" ? "Reverted changes to" : "Changed"
    end
    "#{verb} #{noun}"
  end

  def history_filter_params = params.permit(:q, locales: [], types: [], actors: []).to_h

  def history_events(change)
    events = change.catalog_events
    types = Array(params[:types]) & %w[CatalogKey CatalogText]
    locales = Array(params[:locales]) & CatalogLocale::DATA.keys
    nodes = @project.catalog_nodes
    nodes = nodes.where(payload_type: types) if types.any?
    nodes = nodes.where(payload_type: "CatalogKey").or(nodes.where(payload_type: "CatalogText", payload_id: CatalogText.where(locale: locales).select(:id))) if locales.any?
    if params[:q].present?
      state = CatalogState.new(@project)
      nodes = nodes.where(id: state.items.values.select { |item| state.path(item).include?(params[:q].to_s.first(200)) }.map(&:id))
    end
    events.where(catalog_node_id: nodes.select(:id))
  end
end
