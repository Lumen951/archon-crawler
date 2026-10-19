class Paper < ApplicationRecord
  has_many :sources, class_name: "PaperSource", dependent: :destroy
  has_many :authorships, -> { order(:position) }, class_name: "PaperAuthorship", dependent: :destroy
  has_many :authors, through: :authorships, source: :paper_author

  validates :title, presence: true

  def primary_source
    sources.order(:created_at).first
  end

  def source_labels
    sources.map(&:provider).uniq.map { |provider| provider == "arxiv" ? "arXiv" : "OpenReview" }
  end
end
