class AddModerationFields < ActiveRecord::Migration[8.1]
  def change
    add_column :documents, :moderated_at, :datetime
    add_column :documents, :moderation_reason, :text
    add_index :documents, :moderated_at, where: "moderated_at IS NOT NULL"
  end
end
