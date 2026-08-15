class DashboardController < ApplicationController
  # How long a health check is reused before another page load re-probes.
  STATUS_TTL = 1.minute

  def index
    return forbidden if cannot?(:read, :apps)

    @apps = App.order(:domain, :subdomain).to_a
    @statuses = check_all(@apps, force: params[:recheck].present?)
    @open_exceptions = ExceptionGroup.open_status.group(:app_id).count
    @system = SystemStats.snapshot(previous_cpu: cpu_baseline)
  end

  private

  # Health checks are HTTP requests with a 5s timeout. Doing them inline on
  # every page load made the dashboard as slow as the slowest app, and hammered
  # every site on every refresh. Cache them and let the user force a re-probe.
  def check_all(apps, force: false)
    rails_apps, repos = apps.partition(&:rails_app?)

    statuses = rails_apps.map { |app|
      Thread.new { [ app.id, cached_status(app, force: force) ] }
    }.map(&:value).to_h

    # Repos aren't served over HTTP — there's nothing to health-check.
    repos.each { |app| statuses[app.id] = { status: :repo, detail: "git repo (not served)" } }
    statuses
  end

  def cached_status(app, force: false)
    key = "app_status/#{app.id}"
    Rails.cache.delete(key) if force

    Rails.cache.fetch(key, expires_in: STATUS_TTL) do
      AppStatusChecker.check(app).merge(checked_at: Time.current)
    end
  end

  # /proc/stat counts jiffies since boot, so one read yields the average over
  # 82 days of uptime. Keep the previous read so the figure shown is "since you
  # last looked" rather than "since the machine started".
  def cpu_baseline
    previous = Rails.cache.read("system/cpu_sample")
    Rails.cache.write("system/cpu_sample", SystemStats.cpu_sample, expires_in: 10.minutes)
    previous
  end
end
