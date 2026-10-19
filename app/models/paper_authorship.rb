class PaperAuthorship < ApplicationRecord
  belongs_to :paper
  belongs_to :paper_author

  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :position, uniqueness: { scope: :paper_id }
end
