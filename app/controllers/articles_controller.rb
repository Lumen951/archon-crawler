class ArticlesController < ApplicationController
  def show
    @article = Article.find(params[:id])

    # Cache the rendered content since articles don't change
    @cached_content = Rails.cache.fetch("article_content_#{@article.id}", expires_in: 30.days) do
      @article.clean_content_html.presence || @article.clean_content_markdown
    end
  end
end
