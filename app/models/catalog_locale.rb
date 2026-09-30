class CatalogLocale
  # Unicode CLDR 48 cardinal categories and English locale labels, pinned for reproducibility.
  # Source: unicode-org/cldr-json (Unicode-3.0 license).
  DATA = JSON.parse(Rails.root.join("config/catalog_locales.json").read).freeze
  def self.options = DATA.map { |code, data| {id: code, label: "#{data.fetch('name')} (#{code})"} }.sort_by { |row| row[:label] }
  def self.valid?(code) = DATA.key?(code)
  def self.name(code) = DATA.fetch(code).fetch("name")
  def self.categories(code) = DATA.fetch(code).fetch("categories")
end
