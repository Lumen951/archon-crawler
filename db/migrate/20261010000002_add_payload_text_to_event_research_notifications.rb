class AddPayloadTextToEventResearchNotifications < ActiveRecord::Migration[8.1]
  def change
    add_column :event_research_notifications, :payload_text, :text
  end
end
