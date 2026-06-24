class AddRepoSupportToApps < ActiveRecord::Migration[8.0]
  def change
    # "rails" = a Plesk-served Rails subdomain (the original behaviour).
    # "repo"  = a plain git checkout at a custom path that just runs follow-up
    #           commands after pulling (e.g. a ui-components build).
    add_column :apps, :app_kind, :string, null: false, default: "rails"

    # Where a "repo" app is checked out (Rails apps derive this from Plesk layout).
    add_column :apps, :deploy_path, :string

    # Newline-separated shell commands run after the pull, one step per line.
    add_column :apps, :post_deploy_commands, :text

    # Repos have no subdomain/domain — let those be NULL (SQLite allows many
    # NULLs in the unique index, so repos never collide with each other).
    change_column_null :apps, :subdomain, true
    change_column_null :apps, :domain, true
  end
end
