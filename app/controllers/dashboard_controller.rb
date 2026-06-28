class DashboardController < ApplicationController
  def index
    return forbidden if cannot?(:read, :apps)

    @apps = App.order(:domain, :subdomain).to_a

    # Live status per app, checked concurrently with a short timeout so the
    # dashboard stays snappy even when an app is down.
    @statuses = check_all(@apps)
  end

  private

  def check_all(apps)
    # Repos aren't served over HTTP — there's nothing to health-check.
    rails_apps, repos = apps.partition(&:rails_app?)
    statuses = rails_apps.map { |app| Thread.new { [ app.id, AppStatusChecker.check(app) ] } }
                         .map { |t| t.value }
                         .to_h
    repos.each { |app| statuses[app.id] = { status: :repo, detail: "git repo (not served)" } }
    statuses
  end
end
