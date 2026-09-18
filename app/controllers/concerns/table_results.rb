module TableResults
  private

  def table_results(scope, columns:)
    @query = params[:q].is_a?(String) ? params[:q].strip.first(200) : ""
    if @query.present?
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
      scope = scope.where(columns.map { |column| "#{column} ILIKE :query" }.join(" OR "), query: pattern)
    end
    @pages = [(scope.count + 19) / 20, 1].max
    requested = params[:page].is_a?(String) && params[:page].match?(/\A[0-9]+\z/) ? params[:page].to_i : 1
    @page = requested.clamp(1, @pages)
    scope.limit(20).offset((@page - 1) * 20)
  end
end
