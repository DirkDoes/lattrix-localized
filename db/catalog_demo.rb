# Run explicitly with: bin/rails runner db/catalog_demo.rb
abort "Local development only" unless Rails.env.development?
unless Project.exists?(slug: "catalog_demo")
  project = Project.create!(name: "Catalog demo", slug: "catalog_demo", visibility: "public")
  project.project_memberships.create!(user: User.order(:created_at).first!, role: "owner")
  project.languages.create!(identifier: "nl")
  project.languages.create!(identifier: "ar")
  writer = CatalogWriter.new(project, actor: project.users.first)
  writer.edit(expected: project.revision, summary: "Created example keys") do |edit|
    edit.add_key("account.greeting", description: "The greeting shown after sign-in")
    edit.add_key("account.email", description: "Account email field")
    edit.add_key("notifications", kind: "plural")
    edit.add_key("checkout.pay")
  end
  state = CatalogState.new(project, pending: true)
  keys = state.keys.index_by { |key| state.path(key) }
  writer.edit(expected: project.revision, summary: "Added English and Dutch translations") do |edit|
    {"account.greeting"=>["Hello %{name}", "Hallo %{name}"], "account.email"=>["Email address", "E-mailadres"], "checkout.pay"=>["Pay securely", nil], "notifications.one"=>["One notification", "Eén melding"], "notifications.other"=>["%{count} notifications", "%{count} meldingen"]}.each do |path, values|
      %w[en nl].zip(values).each { |locale, value| edit.translate(keys.fetch(path).id, locale, value) if value }
    end
  end
  writer.edit(expected: project.revision, summary: "Draft awaiting its placeholder") { |edit| edit.translate(keys.fetch("account.greeting").id, "nl", "Welkom") }
end
