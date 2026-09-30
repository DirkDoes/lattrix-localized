class FormatsController < ApplicationController
  layout "settings"
  def index
    @tab = params[:tab] == "import" ? "import" : "export"
    @format = params[:export_format].presence_in(%w[yaml csv xlsx]) || "yaml"
    project = Project.new(name: "Example", slug: "example", source_locale: "en")
    items = {}; paths = {}
    examples = {
      "account.notifications.one" => ["One notification", "Eén melding"],
      "account.notifications.other" => ["%{count} notifications", "%{count} meldingen"],
      "account.profile.email" => ["Email address", "E-mailadres"],
      "account.profile.name" => ["Hello %{name}", "Hallo %{name}"],
      "account.profile.bio" => ["Tell people\nabout yourself.", "Vertel anderen\niets over jezelf."],
      "checkout.pay" => ["Pay securely", nil]
    }
    examples.each do |path, values|
      parent = nil
      path.split(".").each_with_index do |segment, index|
        partial = path.split(".").first(index+1).join(".")
        parent = paths[partial] ||= begin
          kind = partial == "account.notifications" ? "plural" : partial == path ? "scalar" : "branch"
          id = items.size + 1
          items[id] = CatalogState::Item.new(id: id, parent_id: parent&.id, payload: CatalogKey.new(name: segment, kind: kind), deleted: false)
        end
      end
      %w[en nl].zip(values).each do |locale, value|
        next unless value
        id = items.size + 1
        items[id] = CatalogState::Item.new(id: id, parent_id: parent.id, payload: CatalogText.new(locale: locale, value: value), deleted: false)
      end
    end
    @state = CatalogState.new(project, items: items, locales: %w[en nl])
    exporter = CatalogExport.new(project, state: @state)
    @files = @format == "yaml" ? exporter.files.transform_keys { |locale| "#{locale}.yml" } : @format == "csv" ? {"translations.csv" => exporter.download("csv").first} : {}
  end
end
