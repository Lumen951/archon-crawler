class ArticlesController < ApplicationController
  layout "oauth", only: :show

  PLATFORM_ACCOUNT_TYPES = {
    "wechat" => "WechatAccount",
    "rednote" => "RednoteAccount",
    "twitter" => "TwitterAccount",
    "website" => "WebsiteAccount"
  }.freeze

  ARTICLES_PER_PAGE = 25

  def index
    scope = Article.includes(:account).recent

    if params[:platform].present?
      account_type = PLATFORM_ACCOUNT_TYPES[params[:platform].to_s.downcase]
      scope = account_type ? scope.joins(:account).where(accounts: { type: account_type }) : scope.none
    end

    # `.without_count` drops Kaminari's `SELECT COUNT(*)`. That count has no
    # LIMIT, so it cannot use the ordering index and has to evaluate the
    # trigram OR across every article — on production it cost 16-28s, more than
    # the page query it accompanies. Kaminari instead fetches one extra row to
    # decide whether a next page exists, so the view paginates with
    # #next_page/#prev_page rather than the `paginate` helper (which needs
    # total_count, and raises on a without_count relation).
    @articles = scope.search_keyword(params[:keyword])
                    .page(params[:page])
                    .per(ARTICLES_PER_PAGE)
                    .without_count
  end

  def show
    @article = Article.find(params[:id])

    # Cache the rendered content since articles don't change
    # @cached_content = Rails.cache.fetch("article_content_#{@article.id}", expires_in: 30.days) do
    #   @article.clean_content_html.presence || @article.clean_content_markdown
    # end

    @cached_content = @article.clean_content_html.presence || @article.clean_content_markdown
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
