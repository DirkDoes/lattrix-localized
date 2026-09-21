require "zip"
require "tmpdir"
require "caxlsx"
class ExportJob < ApplicationJob
  queue_as :exports
  class Cancelled < StandardError; end
  def perform(id)
    request = ExportRequest.find_by(id: id)
    return unless request
    request.with_lock do
      return unless request.status == "queued"
      request.update!(status: "running", progress: 1)
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    calls = 0
    checkpoint = -> do
      calls += 1
      if calls % 256 == 0
        raise Cancelled if ExportRequest.where(id: id, status: "cancelled").exists?
        raise ArgumentError, "Export exceeded its time limit. Try fewer sheets." if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 900
      end
    end
    sheets = request.accessible_sheets
    options = request.options
    set = request.project.identifier_sets.find(options.fetch("identifier_set_id"))
    identifiers = set.language_identifiers.pluck(:language_id, :identifier).to_h
    format = options.fetch("format")
    event = RecordingEvent.find(options["recording_event_id"]) if options["recording_event_id"]
    workbook = Axlsx::Package.new if format == "xlsx"
    files = []
    Dir.mktmpdir("lattrix-export") do |directory|
      sheets.each_with_index do |sheet, index|
        raise Cancelled if request.reload.status == "cancelled"
        languages = sheet.active_languages.order(:name).to_a
        languages.select! { |language| options["language_ids"].map(&:to_s).include?(language.id.to_s) } if options["language_ids"].any?
        next if languages.empty?
        missing = languages.reject { |language| identifiers.key?(language.id) }
        raise ArgumentError, "Some languages are missing identifiers in this set" if missing.any?
        raise ArgumentError, "Invalid history point" if event && event.recording.translation_tree_id != sheet.translation_tree.id
        exporter = TranslationExport.new(sheet, languages: languages, identifiers: identifiers, descriptions: options["descriptions"], checkpoint: checkpoint, event: event)
        if format == "xlsx"
          title = "#{index + 1} #{sheet.name}".gsub(/[\\\/\?\*\[\]:]/, " ")[0,31]
          workbook.workbook.add_worksheet(name: title) do |worksheet|
            exporter.generate("rows").each { |row| checkpoint.call; worksheet.add_row(row, types: Array.new(row.length, :string), escape_formulas: true) }
          end
        elsif format == "csv"
          path = File.join(directory, "#{sheet.id}.csv")
          File.binwrite(path, exporter.generate("csv"))
          files << ["#{sheet.slug}.csv", path]
        else
          Zip::File.open_buffer(exporter.generate(format)) do |archive|
            archive.each do |entry|
              path = File.join(directory, "#{sheet.id}-#{entry.name}")
              File.binwrite(path, entry.get_input_stream.read)
              files << [sheets.length > 1 ? "#{sheet.slug}/#{entry.name}" : entry.name, path]
            end
          end
        end
        ExportRequest.where(id: id, status: "running").update_all(progress: 5 + ((index + 1) * 85 / sheets.length))
      end
      raise ArgumentError, "No selected languages are available in these sheets" if format == "xlsx" ? workbook.workbook.worksheets.empty? : files.empty?
      result = File.join(directory, "result")
      if format == "xlsx"
        workbook.serialize(result)
        filename = "#{request.project.slug}.xlsx"
      elsif files.length == 1
        FileUtils.cp(files.first.last, result)
        filename = File.basename(files.first.first)
      else
        Zip::File.open(result, create: true) { |zip| files.each { |name, path| checkpoint.call; zip.add(name, path) } }
        filename = "#{request.project.slug}.zip"
      end
      request.accessible_sheets
      request.with_lock do
        raise Cancelled if request.status == "cancelled"
        FileUtils.mkdir_p(request.path.dirname)
        FileUtils.mv(result, request.path)
        request.update!(status: "ready", progress: 100, filename: filename)
      end
    end
  rescue Cancelled
    FileUtils.rm_f(request.path)
  rescue StandardError => error
    Rails.logger.error("Export #{id} failed: #{error.class}: #{error.message}")
    ExportRequest.where(id: id).where.not(status: "cancelled").update_all(status: "failed", error: error.is_a?(ArgumentError) ? error.message : "Could not generate export. Please try again.")
  end
end
