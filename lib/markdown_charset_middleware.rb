# frozen_string_literal: true

# Ensures .md files are served with proper charset so non-ASCII content
# (e.g. Chinese characters) renders correctly in browsers.
class MarkdownCharsetMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)

    if env["PATH_INFO"]&.end_with?(".md")
      headers = headers.dup
      headers["content-type"] = "text/plain; charset=utf-8"
    end

    [status, headers, body]
  end
end
