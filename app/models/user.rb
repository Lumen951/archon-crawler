# == Schema Information
#
# Table name: users
#
#  id                 :bigint           not null, primary key
#  email_address      :string           not null
#  email_confirmed_at :datetime
#  last_login_at      :datetime
#  name               :string
#  password_digest    :string
#  role               :integer          default(0), not null
#  settings           :json
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  mp_id              :string
#
# Indexes
#
#  index_users_on_email_address  (email_address) UNIQUE
#  index_users_on_mp_id          (mp_id) UNIQUE
#  index_users_on_role           (role)
#
class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :groups, dependent: :destroy
  has_many :user_tags, dependent: :destroy
  has_many :paper_import_tasks, dependent: :destroy
  has_many :paper_subscriptions, dependent: :destroy
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
  validate :email_address_unchanged, on: :update
  validates :password, length: { minimum: 12 }, confirmation: true, on: :registration
  validates :password_confirmation, presence: true, on: :registration
  validate :enterprise_registration, on: :registration

  def enterprise_email?
    email_address.to_s.split("@", -1).length == 2 && email_address.split("@").last == "archon.tech"
  end

  def enterprise_email_verified?
    enterprise_email? && email_confirmed? && settings["mailbox_verified"] == true
  end

  def password_login_allowed?
    email_confirmed? || enterprise_email?
  end

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

  def self.developer_account!
    raise "Developer account is only available locally" unless Rails.env.development? || Rails.env.test?

    find_or_create_by!(email_address: "developer@archon.test") do |user|
      user.name = "Archon Developer"
      user.password = generate_random_password(32)
      user.role = :admin
      user.email_confirmed_at = Time.current
    end
  end

  def self.ransackable_attributes(auth_object = nil)
    %w[email_address name role created_at last_login_at]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[]
  end

  private

  def enterprise_registration
    errors.add(:email_address, "仅支持 @archon.tech 企业邮箱") unless enterprise_email?
  end

  def email_address_unchanged
    if will_save_change_to_email_address?
      errors.add(:email_address, "暂不支持更换邮箱，请联系管理员")
    end
  end
end
