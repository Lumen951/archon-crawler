module EventResearch
  class SearchApiKeyError < StandardError; end

  class SearchApiError < StandardError
    attr_reader :status

    def initialize(message, status: nil)
      @status = status
      super(message)
    end
  end
end
