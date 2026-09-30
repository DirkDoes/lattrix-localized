class UseStandardLocaleIdentifiers < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :languages, name: "language_identity"
    add_check_constraint :languages, "length(name)>0 AND identifier ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$'", name: "language_identity"
  end
end
