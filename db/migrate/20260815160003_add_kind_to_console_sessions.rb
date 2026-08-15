class AddKindToConsoleSessions < ActiveRecord::Migration[8.0]
  # Every session that exists today is a `rails console`, and ConsoleRunner
  # reads this column on every spawn — so it has to be NOT NULL with that
  # default rather than nullable-meaning-rails.
  def change
    add_column :console_sessions, :kind, :string, default: "rails", null: false
  end
end
