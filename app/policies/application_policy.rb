class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user, @record = user, record
  end

  def access?
    user.present? && user.application_access?
  end

  def administration?
    access? && (user.admin? || user.owner?)
  end

  def index? = false
  def show? = false
  def create? = false
  def update? = false
  def destroy? = false
  def new? = create?
  def edit? = update?

  class Scope
    attr_reader :user, :scope
    def initialize(user, scope)
      @user, @scope = user, scope
    end
    def resolve
      raise NotImplementedError, "Define an explicit policy scope"
    end
    private
    def access? = ApplicationPolicy.new(user, nil).access?
    def administration? = ApplicationPolicy.new(user, nil).administration?
  end
end
