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
