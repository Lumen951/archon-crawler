class PaperSubscription < ApplicationRecord
  belongs_to :user
  belongs_to :paper_author
  belongs_to :seed_paper, class_name: "Paper"
  has_many :matches, class_name: "PaperSubscriptionMatch", dependent: :destroy
  has_many :sync_runs, class_name: "PaperSyncRun", dependent: :destroy

  validates :display_name, presence: true
  validate :valid_names

  def self.normalize_name(name)
    name.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^\p{L}\p{N}\s]/, " ").squish
  end

  def latest_run
    sync_runs.order(id: :desc).first
  end

  def start_sync!
    run = nil
    with_lock do
      return unless enabled?
      previous = latest_run
      return previous if previous&.active?
      return previous if previous&.retry_at && previous.retry_at > Time.current

      if previous && !previous.completed?
        previous.update!(status: :paused, run_token: SecureRandom.uuid)
      end
      run = sync_runs.create!(name_variants: name_variants, cutoff_at: Time.current,
        run_token: SecureRandom.uuid)
    end
    run.enqueue!
    run.reload
  end

  def resume_sync!
    run = nil
    with_lock do
      return unless enabled?
      run = latest_run
      return unless run&.resumable?
      return unless run.name_variants == name_variants

      run.update!(status: :queued, run_token: SecureRandom.uuid, error_message: nil, retry_at: nil)
    end
    run.enqueue!
    run.reload
  end

  def pause!
    with_lock do
      update!(enabled: false)
      sync_runs.where(status: %w[queued running]).update_all(
        status: "paused", run_token: SecureRandom.uuid, updated_at: Time.current
      )
    end
  end

  private

  def valid_names
    unless name_variants.is_a?(Array) && name_variants.length.between?(1, 5) &&
        name_variants.all? { |name| name.is_a?(String) && name.length.between?(2, 100) &&
          name.match?(/\A[\p{L}\p{M}\s.'’\-]+\z/) && name.match?(/\p{L}/) }
      errors.add(:name_variants, "请填写 1–5 个姓名，每个 2–100 字，不含查询语法")
    end
  end
end
