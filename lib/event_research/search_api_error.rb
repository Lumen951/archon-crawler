require_relative "search_error"

module EventResearch
  class SearchApiError < SearchError
    attr_reader :status

    def initialize(message, status: nil)
      @status = status
      super(message)
    end
  end
end
