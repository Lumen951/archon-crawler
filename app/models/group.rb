class Group < ApplicationRecord
  belongs_to :user
  has_many :group_accounts, dependent: :destroy
  has_many :accounts, through: :group_accounts

  validates :ref_key, presence: true,
                      format: { with: /\A[a-zA-Z0-9_-]+\z/, message: "只能包含字母、数字、下划线和连字符" }
  validates :ref_key, uniqueness: { scope: :user_id, message: "该用户已存在相同的 ref_key" }
end
