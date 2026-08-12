class ArticlesController < ApplicationController
  def show
    @article = Article.find(params[:id])

    # Cache the rendered content since articles don't change
    @cached_content = Rails.cache.fetch("article_content_#{@article.id}", expires_in: 30.days) do
      @article.clean_content_html.presence || @article.clean_content_markdown
    end
  end

  def download_content
    @article = Article.find(params[:id])

    if @article.download_content!
      redirect_to article_path(@article), notice: "文章内容已更新。"
    else
      redirect_to article_path(@article), alert: "无法下载文章内容，请检查文章链接。"
    end
  end
end
