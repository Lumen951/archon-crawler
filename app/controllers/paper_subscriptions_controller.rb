class PaperSubscriptionsController < ApplicationController
  before_action :set_subscription, only: %i[show update sync resume review]

  def index
    @subscriptions = current_user.paper_subscriptions.includes(:seed_paper).order(updated_at: :desc).page(params[:page]).per(20)
    render "papers/subscriptions"
  end

  def create
    authorship = PaperAuthorship.includes(:paper).find(params[:authorship_id])
    raise ActiveRecord::RecordNotFound unless authorship.paper.sources.arxiv.exists?

    @subscription = current_user.paper_subscriptions.create_or_find_by!(paper_author_id: authorship.paper_author_id) do |record|
      record.seed_paper = authorship.paper
      record.display_name = authorship.display_name
      record.name_variants = [ authorship.display_name ]
    end
    @subscription.start_sync! if @subscription.sync_runs.empty?
    redirect_to paper_subscription_path(@subscription)
  rescue ActiveRecord::RecordInvalid
    redirect_to papers_path, flash: { error: "作者姓名不能用于检索，请检查署名" }
  end

  def show
    @run = @subscription.latest_run
    scope = @subscription.matches.includes(paper_source: :paper)
    scope = scope.where(status: params[:status]) if PaperSubscriptionMatch.statuses.key?(params[:status])
    @matches = scope.order(id: :desc).page(params[:page]).per(20)
    @counts = @subscription.matches.group(:status).count
    render "papers/subscription"
  end

  def update
    if params[:operation] == "pause"
      @subscription.pause!
    elsif params[:operation] == "enable"
      @subscription.update!(enabled: true)
    else
      names = params[:name_variants].to_s.lines.map(&:strip).reject(&:blank?).uniq
      @subscription.with_lock do
        if @subscription.latest_run&.active?
          return redirect_to paper_subscription_path(@subscription), flash: { error: "请先暂停当前回溯，再修改姓名别名" }
        end
        @subscription.update!(name_variants: names)
      end
    end
    redirect_to paper_subscription_path(@subscription), flash: { success: "关注设置已更新" }
  rescue ActiveRecord::RecordInvalid => e
    redirect_to paper_subscription_path(@subscription), flash: { error: e.record.errors.full_messages.join("；") }
  end

  def sync
    @subscription.start_sync!
    redirect_to paper_subscription_path(@subscription)
  end

  def resume
    @subscription.resume_sync!
    redirect_to paper_subscription_path(@subscription)
  end

  def review
    match = @subscription.matches.find(params[:match_id])
    unless %w[confirmed excluded pending].include?(params[:decision])
      return head :unprocessable_entity
    end
    match.review!(params[:decision])
    redirect_to paper_subscription_path(@subscription), flash: { success: "论文归属已更新" }
  end

  private

  def set_subscription
    @subscription = current_user.paper_subscriptions.find(params[:id])
  end
end
