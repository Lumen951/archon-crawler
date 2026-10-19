class PaperSource < ApplicationRecord
  belongs_to :paper

  validates :provider, :external_id, :canonical_url, presence: true
  validates :external_id, uniqueness: { scope: :provider }

  enum :provider, { arxiv: "arxiv", openreview: "openreview" }
end
