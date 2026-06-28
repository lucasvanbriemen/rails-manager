class RemoveSourceModeDromApps < ActiveRecord::Migration[8.0]
  def change
    remove_column :apps, :source_mode
  end
end
