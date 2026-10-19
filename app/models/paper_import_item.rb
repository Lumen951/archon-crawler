class PaperImportItem < ApplicationRecord
  belongs_to :paper_import_task
  belongs_to :paper, optional: true

  enum :status, { pending: 0, imported: 1, failed: 2 }

  validates :url, presence: true, uniqueness: { scope: :paper_import_task_id }
end
