# == Schema Information
#
# Table name: user_tags
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  tag_id     :bigint           not null
#  user_id    :bigint           not null
#
# Indexes
#
#  index_user_tags_on_tag_id              (tag_id)
#  index_user_tags_on_user_id             (user_id)
#  index_user_tags_on_user_id_and_tag_id  (user_id,tag_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (tag_id => tags.id)
#  fk_rails_...  (user_id => users.id)
#
class UserTag < ApplicationRecord
  belongs_to :user
  belongs_to :tag

  validates :tag_id, uniqueness: { scope: :user_id }
end
