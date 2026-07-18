class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :groups, dependent: :destroy
  has_many :user_tags, dependent: :destroy
  has_many :followed_tags, through: :user_tags, source: :tag

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  enum :role, { user: 0, admin: 1 }, default: :user

  store :settings, coder: JSON
  store_accessor :settings, :notify_api_key_expiry

  # Admins opt in to notifications explicitly
  def notify_api_key_expiry?
    return false unless admin?
    notify_api_key_expiry == "1" || notify_api_key_expiry == true
  end

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

  # Find or create user from OAuth response
  def self.from_oauth(user_hash)
    if user_hash[:mp_id].blank?
      raise ArgumentError, "No mp_id in OAuth response: #{user_hash.inspect}"
    end

    find_or_initialize_by(mp_id: user_hash[:mp_id]).tap do |user|
      is_new = user.new_record?
      user.email_address = user_hash[:email].to_s.strip.presence || "user-#{user_hash[:mp_id]}@miracleplus.com"
      user.name = user_hash[:name].to_s.strip.presence
      user.password = SecureRandom.hex(32) if is_new
      user.role = :admin if is_new && !User.exists? # First user becomes admin
      user.save!
    end
  end

  # Check if user is OAuth-only (no password set)
  def oauth_only?
    password_digest.blank? && mp_id.present?
  end
end
