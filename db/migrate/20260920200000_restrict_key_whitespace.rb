class RestrictKeyWhitespace < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :translation_keys, "name !~ '[[:space:]]'", name: "translation_key_no_whitespace", validate: false
  end
end
