class Admin::TagsController < Admin::BaseController
  before_action :set_tag, only: [:edit, :update, :destroy]

  def index
    @tags = Tag.ordered
  end

  def edit
  end

  def update
    if @tag.update(tag_params)
      redirect_to admin_tags_path, notice: "标签「#{@tag.name}」已更新"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    count = @tag.tag_accounts_count
    @tag.destroy
    redirect_to admin_tags_path, notice: "标签「#{@tag.name}」已删除（#{count} 个帐号关联已移除）"
  end

  def refresh_counts
    Tag.find_each do |tag|
      Tag.reset_counters(tag.id, :tag_accounts)
    end
    redirect_to admin_tags_path, notice: "标签计数已刷新"
  end

  private

  def set_tag
    @tag = Tag.find(params[:id])
  end

  def tag_params
    params.require(:tag).permit(:name, :color, :description, :position)
  end
end
