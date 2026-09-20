class RequireSheetDefaultLanguage < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      INSERT INTO languages (id,project_id,name,identifier,enabled,created_at,updated_at)
      SELECT gen_random_uuid(),p.id,'English','en',true,NOW(),NOW() FROM projects p
      WHERE EXISTS(SELECT 1 FROM sheets WHERE project_id=p.id AND default_language_id IS NULL)
      AND NOT EXISTS(SELECT 1 FROM languages WHERE project_id=p.id AND enabled)
      ON CONFLICT(project_id,identifier) DO UPDATE SET enabled=true;
      UPDATE sheets s SET default_language_id=(SELECT id FROM languages WHERE project_id=s.project_id AND enabled ORDER BY created_at LIMIT 1) WHERE default_language_id IS NULL;
    SQL
    change_column_null :sheets, :default_language_id, false
  end
  def down
    change_column_null :sheets, :default_language_id, true
  end
end
