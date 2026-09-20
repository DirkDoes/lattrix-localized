class LanguagesController < ApplicationController
  after_action :verify_authorized

  def create
    save_language(new_record: true)
  end

  def update
    save_language(new_record: false)
  end

  private

  def save_language(new_record:)
    project = policy_scope(Project).find_by!(slug: params[:project_id])
    language = new_record ? project.languages.new : project.languages.find(params[:id])
    authorize language, new_record ? :create? : :update?
    attributes = params.require(:language).permit(:name, :identifier, :enabled, sheet_ids: [])
    @project = project
    project.with_lock do
      if new_record && attributes[:identifier].blank?
        base = attributes[:name].to_s.parameterize(separator: "_").presence || "language"
        identifier = base; suffix = 1
        while project.languages.exists?(identifier: identifier)
          suffix += 1; identifier = "#{base}_#{suffix}"
        end
        attributes[:identifier] = identifier
      end
      if attributes.key?(:sheet_ids)
        ids = attributes.delete(:sheet_ids).reject(&:blank?).uniq
        raise ArgumentError, "Select sheets belonging to this project" unless project.sheets.where(id: ids).count == ids.length
        required = project.sheets.where(default_language_id: language.id)
        if ids.any? && required.where.not(id: ids).exists?
          raise ArgumentError, "This language is the default for #{required.where.not(id: ids).pluck(:name).join(', ')}. Change those defaults first."
        end
        # Empty selection means project-wide; retain existing translations and assignments.
        language.assign_attributes(attributes.except(:enabled))
        language.enabled = ids.empty?
        if language.persisted?
          language.sheet_languages.update_all(enabled: false)
          ids.each { |id| language.sheet_languages.find_or_initialize_by(sheet_id: id).update!(enabled: true) }
        end
        language.save!
        ids.each { |id| language.sheet_languages.find_or_initialize_by(sheet_id: id).update!(enabled: true) }
      else
        language.update!(attributes)
      end
    end
    respond_to do |format|
      format.json { render json: {url: project_language_path(project,language), message: "Language saved.", rows: (new_record && project.advanced_languages? ? render_to_string(partial: "projects/language_identifiers", locals: {language: language}, formats: [:html]) : nil)} }
      format.html { redirect_to settings_project_path(project), notice: "Language saved." }
    end
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    message = error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages.to_sentence : error.message
    respond_to do |format|
      format.json { render json: {error: message}, status: :unprocessable_entity }
      format.html { redirect_to settings_project_path(project), alert: message }
    end
  end
end
