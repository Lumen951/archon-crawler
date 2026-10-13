class EventWeeklyDigestsController < ApplicationController
  before_action :require_admin, only: :resend

  def index
    @digests = EventWeeklyDigest.recent.limit(30)
  end

  def show
    @digest = EventWeeklyDigest.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to event_weekly_digests_path, flash: { error: "研究报告不存在" }
  end

  def resend
    digest = EventWeeklyDigest.find(params[:id])
    EventWeeklyDigestResendJob.perform_later(digest.id)
    redirect_to event_weekly_digest_path(digest), flash: { success: "已加入重新推送队列" }
  rescue ActiveRecord::RecordNotFound
    redirect_to event_weekly_digests_path, flash: { error: "研究报告不存在" }
  end
end
