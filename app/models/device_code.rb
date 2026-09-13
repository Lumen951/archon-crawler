# == Schema Information
#
# Table name: device_codes
#
#  id          :bigint           not null, primary key
#  device_code :string           not null
#  expires_at  :datetime         not null
#  interval    :integer          default(5), not null
#  ip_address  :string
#  scope       :string
#  status      :integer          default(0), not null
#  user_code   :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  client_id   :string           not null
#  user_id     :bigint
#
# Indexes
#
#  index_device_codes_on_device_code  (device_code) UNIQUE
#  index_device_codes_on_expires_at   (expires_at)
#  index_device_codes_on_user_code    (user_code) UNIQUE
#  index_device_codes_on_user_id      (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class DeviceCode < ApplicationRecord
  belongs_to :user, optional: true

  enum :status, { pending: 0, authorized: 1, expired: 2, denied: 3 }

  validates :device_code, presence: true, uniqueness: true
  validates :user_code, presence: true, uniqueness: true
  validates :client_id, presence: true
  validates :expires_at, presence: true

  before_validation :generate_codes, on: :create

  scope :active, -> { pending.where("expires_at > ?", Time.current) }

  def expired?
    expires_at < Time.current
  end

  def authorize!(user)
    update!(user: user, status: :authorized)
  end

  def deny!
    update!(status: :denied)
  end

  def mark_expired!
    update!(status: :expired) if pending?
  end

  def self.generate_user_code
    chars = %w[A B C D E F G H J K L M N P Q R S T U V W X Y Z 2 3 4 5 6 7 8 9]
    code = 8.times.map { chars.sample }.join
    "#{code[0..3]}-#{code[4..7]}"
  end

  private

  def generate_codes
    self.device_code ||= SecureRandom.hex(20)
    self.user_code ||= self.class.generate_user_code
    self.expires_at ||= 15.minutes.from_now
  end
end
