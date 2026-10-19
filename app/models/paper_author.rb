class PaperAuthor < ApplicationRecord
  has_many :authorships, class_name: "PaperAuthorship", dependent: :restrict_with_exception
  has_many :papers, through: :authorships

  validates :display_name, :normalized_name, presence: true

  before_validation :normalize_name

  private

  def normalize_name
    self.normalized_name = display_name.to_s.downcase.squish if display_name.present?
  end
end
