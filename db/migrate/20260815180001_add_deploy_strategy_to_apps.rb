class AddDeployStrategyToApps < ActiveRecord::Migration[8.0]
  # Which deploy path DeployRunner takes. Defaults to in_place — today's
  # behaviour — on purpose: switching an app to atomic releases changes where
  # its code lives on disk (app_path/current instead of app_path), which needs
  # its vhost repointed in the same breath. Nothing may move until somebody
  # asks for it, app by app.
  def change
    add_column :apps, :deploy_strategy, :string, null: false, default: "in_place"
  end
end
