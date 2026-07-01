class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  enum :role, { user: 0, admin: 1 }, default: :user

  validates :email_address, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }

  def email_confirmed?
    email_confirmed_at.present?
  end

  def confirm_email!
    update!(email_confirmed_at: Time.current)
  end

  def generate_email_confirmation_token
    signed_id(purpose: :email_confirmation, expires_in: 24.hours)
  end

  def self.find_by_email_confirmation_token(token)
    find_signed(token, purpose: :email_confirmation)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    nil
  end

  # Generate a magic link token that expires in 15 minutes (or custom duration)
  def generate_magic_link_token(expires_in: 15.minutes)
    signed_id(purpose: :magic_link, expires_in: expires_in)
  end

  # Find user by magic link token
  def self.find_by_magic_link_token(token)
    find_signed(token, purpose: :magic_link)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    nil
  end

  # Generate a random password for admin-created users
  def self.generate_random_password(length = 12)
    SecureRandom.alphanumeric(length)
  end

  # Generate password reset token
  def generate_password_reset_token
    signed_id(purpose: :password_reset, expires_in: 15.minutes)
  end

  # Find user by password reset token
  def self.find_by_password_reset_token!(token)
    find_signed!(token, purpose: :password_reset)
  end

  # Check if user has ever logged in
  def ever_logged_in?
    last_login_at.present?
  end
end
