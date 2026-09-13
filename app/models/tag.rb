# == Schema Information
#
# Table name: tags
#
#  id                 :bigint           not null, primary key
#  color              :string           default("#6366f1")
#  description        :text
#  name               :string           not null
#  name_normalized    :string           not null
#  position           :integer          default(0)
#  tag_accounts_count :integer          default(0)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
# Indexes
#
#  index_tags_on_name_normalized  (name_normalized) UNIQUE
#  index_tags_on_position         (position)
#
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
