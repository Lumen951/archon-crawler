class PaperSource < ApplicationRecord
  belongs_to :paper
  has_many :full_texts, class_name: "PaperFullText", dependent: :destroy

  validates :provider, :external_id, :canonical_url, presence: true
  validates :external_id, uniqueness: { scope: :provider }

  enum :provider, { arxiv: "arxiv", openreview: "openreview" }

  def arxiv_version
    return unless arxiv?
    return raw_metadata["version"].to_i if raw_metadata["version"].to_i.positive?

    document = Nokogiri::XML(raw_metadata["xml"].to_s) { |config| config.strict.nonet }
    identifier = document.at_xpath("//*[local-name()='entry']/*[local-name()='id']")&.text.to_s
    identifier[%r{\Ahttps?://arxiv\.org/abs/#{Regexp.escape(external_id)}v([1-9]\d*)\z}, 1]&.to_i
  rescue Nokogiri::XML::SyntaxError
    nil
  end

  def prepare_full_text!
    version = arxiv_version
    return unless version

    full_texts.create_or_find_by!(version: version)
  end
end
