class FormatsController < ApplicationController
  layout "settings"

  def index
    @tab = params[:tab] == "import" ? "import" : "export"
    @format = params[:export_format].presence_in(TranslationExport::FORMATS) || "yaml"
    @pluralization = params.fetch(:pluralization, "1") == "1"
    @parent_translations = params.fetch(:parent_translations, "1") == "1"
    @missing_value_behavior = params[:missing_value_behavior].presence_in(%w[omit empty fallback]) || "omit"
    @delimiter = "."
    @wildcard_format = '${...}'
    build_preview if @tab == "export"
  end

  private

  def build_preview
    dutch_pay = { "empty" => "", "fallback" => "Pay securely" }[@missing_value_behavior]
    @preview_rows = [
      { segments: %w[account notifications], plural_parent: true },
      { segments: %w[account notifications one], plural_form: true, en: "1 notification", nl: "1 melding" },
      { segments: %w[account notifications other], plural_form: true, en: "${count} notifications", nl: "${count} meldingen" },
      { segments: %w[account profile], en: (@parent_translations ? "Profile" : nil), nl: (@parent_translations ? "Profiel" : nil), branch_only: !@parent_translations },
      { segments: %w[account profile email], en: "Email address", nl: "E-mailadres" },
      { segments: %w[account profile name], en: "Display name", nl: "Weergavenaam" },
      { segments: %w[account profile bio], en: "Tell people\nabout yourself.", nl: "Vertel anderen\niets over jezelf." },
      { segments: %w[checkout pay], en: "Pay securely", nl: dutch_pay }
    ]
    @preview_rows.reject! { |row| row[:plural_parent] } unless @pluralization

    english = nested_preview("Profile", "Pay securely")
    dutch = nested_preview("Profiel", dutch_pay)
    @preview_files = case @format
    when "yaml", "json" then TranslationExport.files(@format, {"en" => english, "nl" => dutch})
    when "csv" then [ [ "translations.csv", TranslationExport.csv(csv_rows) ] ]
    else []
    end
  end

  def nested_preview(profile, pay)
    profile_values = {
      "email" => profile == "Profile" ? "Email address" : "E-mailadres",
      "name" => profile == "Profile" ? "Display name" : "Weergavenaam",
      "bio" => profile == "Profile" ? "Tell people\nabout yourself." : "Vertel anderen\niets over jezelf."
    }
    profile_values = { "0" => profile }.merge(profile_values) if @parent_translations
    checkout = {}
    checkout["pay"] = pay unless pay.nil?
    tree = {
      "account" => {
        "notifications" => { "one" => profile == "Profile" ? "1 notification" : "1 melding", "other" => profile == "Profile" ? "${count} notifications" : "${count} meldingen" },
        "profile" => profile_values
      }
    }
    tree["checkout"] = checkout if checkout.any?
    tree
  end

  def csv_rows
    [ %w[key en nl], *@preview_rows.filter_map do |row|
      next if row[:plural_parent] || row[:branch_only]
      [ row[:segments].join(@delimiter), row[:en], row[:nl] ]
    end ]
  end
end
