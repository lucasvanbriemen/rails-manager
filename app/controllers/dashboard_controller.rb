class DashboardController < ApplicationController
  def index
    @apps = App.order(:domain, :subdomain).to_a

    # Live status per app, checked concurrently with a short timeout so the
    # dashboard stays snappy even when an app is down.
    @statuses = check_all(@apps)

    # Plesk subdomains that look like Rails apps but aren't tracked yet.
    @untracked = untracked_rails_subdomains
  rescue StandardError => e
    @apps ||= []
    @statuses ||= {}
    @untracked = []
    flash.now[:alert] = "Could not query Plesk: #{e.message}"
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

  def untracked_rails_subdomains
    tracked = App.pluck(:subdomain, :domain).map { |s, d| "#{s}.#{d}" }.to_set
    Plesk.domains.select { |d| d[:www_root].to_s.end_with?("/public") }
         .reject { |d| tracked.include?(d[:fqdn]) }
  rescue StandardError
    []
  end
end
