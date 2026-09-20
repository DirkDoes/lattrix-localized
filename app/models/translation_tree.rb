class TranslationTree < ApplicationRecord
  belongs_to :sheet
  has_many :recordings, dependent: :delete_all

  # Traverse once from the selected tree; never resolve ownership separately for every row.
  def key_rows(view: "keys", sort: "alphabetical", languages: [], after: nil, limit: 50, group_plurals: true, query: "", hide_parents: false)
    quote = ->(v) { self.class.connection.quote(v) }
    ids = languages.map { |id| quote.call(id) }.join(',')
    ids = "NULL" if ids.empty?
    order = case sort
    when "recent" then "activity DESC, path COLLATE \"C\", id"
    when "relevance" then "filled ASC, path COLLATE \"C\", id"
    else "path COLLATE \"C\", id"
    end
    order = 'segments, id' if view == 'tree'
    pattern = quote.call("%#{ApplicationRecord.sanitize_sql_like(query)}%")
    search_filter = if query.blank?
      "TRUE"
    elsif view == "tree"
      "EXISTS(SELECT 1 FROM matched m WHERE m.segments[1:cardinality(ranked.segments)]=ranked.segments)"
    elsif group_plurals
      "(ranked.id IN(SELECT id FROM matched) OR (ranked.pluralized AND EXISTS(SELECT 1 FROM matched m WHERE m.parent_id=ranked.id AND m.name=ANY(ARRAY[#{sheet.plural_categories.map { |name| quote.call(name) }.join(',')}]::text[]))))"
    else
      "ranked.id IN(SELECT id FROM matched)"
    end
    sql = <<~SQL
      WITH RECURSIVE keys AS (
        SELECT r.*, k.name, k.pluralized, k.name::text AS path, ARRAY[k.name]::text[] AS segments, 0 AS depth
        FROM recordings r JOIN translation_keys k ON k.id=r.recordable_id
        WHERE r.translation_tree_id=#{quote.call(id)} AND r.recordable_type='TranslationKey' AND r.deleted_at IS NULL AND r.parent_id IS NULL
        UNION ALL
        SELECT r.*, k.name,k.pluralized, keys.path || #{quote.call(sheet.delimiter)} || k.name, keys.segments || k.name, keys.depth+1
        FROM recordings r JOIN keys ON r.parent_id=keys.id JOIN translation_keys k ON k.id=r.recordable_id
        WHERE r.translation_tree_id=#{quote.call(id)} AND r.recordable_type='TranslationKey' AND r.deleted_at IS NULL
      ), matched AS (
        SELECT keys.* FROM keys WHERE path ILIKE #{pattern} OR EXISTS(
          SELECT 1 FROM recordings v JOIN text_translations t ON t.id=v.recordable_id
          WHERE v.parent_id=keys.id AND v.recordable_type='TextTranslation' AND v.deleted_at IS NULL AND t.language_id IN (#{ids}) AND t.text ILIKE #{pattern}
        )
      ), ranked AS (
        SELECT keys.*, (SELECT count(*) FROM recordings v JOIN text_translations t ON t.id=v.recordable_id WHERE v.parent_id=keys.id AND v.recordable_type='TextTranslation' AND v.deleted_at IS NULL AND t.language_id IN (#{ids})) AS filled,
        GREATEST(keys.updated_at, (SELECT max(updated_at) FROM recordings WHERE parent_id=keys.id)) AS activity,
        EXISTS(SELECT 1 FROM recordings WHERE parent_id=keys.id AND recordable_type='TranslationKey' AND deleted_at IS NULL) AS has_children
        , EXISTS(SELECT 1 FROM recordings p JOIN translation_keys pk ON pk.id=p.recordable_id JOIN sheets s ON s.id=#{quote.call(sheet_id)}
          WHERE p.id=keys.parent_id AND p.recordable_type='TranslationKey' AND pk.pluralized AND s.pluralization_enabled AND keys.name=ANY(s.plural_categories)) AS plural_form
        FROM keys
      ), numbered AS (SELECT ranked.*, row_number() OVER(ORDER BY #{order}) AS position FROM ranked
        WHERE #{group_plurals ? "NOT plural_form" : "TRUE"} AND #{search_filter} AND #{hide_parents && view != "tree" ? "(NOT has_children OR (pluralized AND #{sheet.pluralization_enabled? ? 'TRUE' : 'FALSE'}))" : "TRUE"}
      )
      SELECT * FROM numbered WHERE position > #{after.to_i} ORDER BY position LIMIT #{limit.to_i}
    SQL
    self.class.connection.select_all(sql).to_a
  end
end
