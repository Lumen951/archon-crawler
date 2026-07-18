class TagAccount < ApplicationRecord
  belongs_to :tag, counter_cache: true
  belongs_to :account

  validates :account_id, uniqueness: { scope: :tag_id }
end
