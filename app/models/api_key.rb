# == Schema Information
#
# Table name: api_keys
#
#  id           :bigint           not null, primary key
#  active       :boolean          default(TRUE)
#  name         :string           not null
#  rate_limit   :integer          default(100)
#  token        :string
#  token_digest :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null
#
# Indexes
#
#  index_api_keys_on_token         (token) UNIQUE
#  index_api_keys_on_token_digest  (token_digest) UNIQUE
#  index_api_keys_on_user_id       (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class ApiKey < ApplicationRecord
  belongs_to :user

  has_secure_token :token

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }

  before_validation :generate_token_digest, on: :create

  def self.find_by_token(token)
    active.find_by(token_digest: digest_token(token))
  end

  def self.digest_token(token)
    Digest::SHA256.hexdigest(token)
  end

  private

  def generate_token_digest
    return if token.blank?
    self.token_digest = self.class.digest_token(token)
  end
end
