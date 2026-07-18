class Tag < ApplicationRecord
  has_many :tag_accounts, dependent: :destroy
  has_many :accounts, through: :tag_accounts
  has_many :user_tags, dependent: :destroy
  has_many :followers, through: :user_tags, source: :user

  validates :name, presence: true
  validates :name_normalized, presence: true, uniqueness: true

  before_validation :normalize_name

  scope :ordered, -> { order(position: :asc, name: :asc) }
  scope :search, ->(query) { where("name_normalized LIKE ?", "%#{sanitize_sql_like(query.to_s.strip.downcase)}%") }

  def self.find_or_create_by_name(raw_name)
    normalized = raw_name.to_s.strip.downcase
    return nil if normalized.blank?

    find_or_create_by!(name_normalized: normalized) do |tag|
      tag.name = raw_name.to_s.strip
    end
  end

  private

  def normalize_name
    self.name = name.to_s.strip
    self.name_normalized = name.downcase
  end
end
