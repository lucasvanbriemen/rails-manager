require "fileutils"

# Untracking an app, for real: stop and forget its workers, delete its files,
# and only then destroy the record.
#
# The record used to be all that went, which left a running systemd unit and a
# checkout on disk that nothing knew about any more. Deleting them is what was
# asked for — but "rm -rf a path out of the database" is the single most
# dangerous thing in this codebase, so every branch below is a refusal:
#
#   * An apex site's directory is the webspace's httpdocs/. Deleting it takes
#     out the domain itself, not one app, so an apex row is NEVER a delete.
#   * A path one level under /var/www/vhosts is a webspace root — six
#     subscriptions and every app inside them. Two levels is an app.
#   * A symlink is not the directory it points at, and following one is how a
#     path that passed every check above still deletes something else.
#   * A path a second App row also points at is shared. ui-components is
#     mounted into every app on this box; removing it because one consumer was
#     untracked would take all of them down.
#
# Nothing here raises. A teardown that fails halfway must still report what it
# did and did not do, because the record is about to go and this is the last
# moment anyone can be told.
class AppTeardown
  # Injectable so the guard can be tested against a temporary tree. Production
  # always passes the real one.
  def self.call(app, root: App::VHOSTS_ROOT, agent: Agent)
    new(app, root: root, agent: agent).call
  end

  def initialize(app, root: App::VHOSTS_ROOT, agent: Agent)
    @app   = app
    @root  = File.expand_path(root)
    @agent = agent
    @notes = []
  end

  # Returns the lines describing what happened, in the order it happened.
  def call
    remove_workers!
    remove_files!
    @notes
  end

  private

  attr_reader :app, :agent

  # --- workers ---------------------------------------------------------------

  def remove_workers!
    services = app.process_services.to_a
    return if services.empty?

    services.each { |service| remove_worker!(service) }
  end

  def remove_worker!(service)
    unit = service.unit_name

    stop = agent.call("systemd.restart", unit: unit, action: "stop")
    @notes << "could not stop #{unit}: #{reason(stop)}" unless stop.ok

    disable = agent.call("systemd.disable", unit: unit)
    @notes << "could not disable #{unit}: #{reason(disable)}" unless disable.ok

    # An adopted worker's unit file was written by somebody else — a hand-written
    # unit or a supervisor program. Stopping it is this app's business; deleting
    # a file the manager never wrote is not.
    if service.managed?
      removed = agent.call("systemd.unit.remove", unit: unit)
      @notes << (removed.ok ? "removed #{unit}" : "could not remove #{unit}: #{reason(removed)}")
    else
      @notes << "stopped #{unit}; its unit file is not the manager's to delete (adopted)"
    end

    service.destroy
  end

  def reason(result) = result.err.presence || "the agent refused"

  # --- files -----------------------------------------------------------------

  def remove_files!
    path = removable_path
    return @notes << "left the files in place — #{@refusal}" if path.nil?

    FileUtils.rm_rf(path, secure: true)
    @notes << "deleted #{path}"
  rescue SystemCallError => e
    @notes << "could not delete #{path}: #{e.message}"
  end

  def removable_path
    path = app.app_path.to_s
    return refuse("no path is recorded for it") if path.blank?

    path = File.expand_path(path)

    return refuse("#{app.fqdn} is an apex domain, so #{path} is the whole webspace's document root") if app.apex?
    return refuse("#{path} is outside #{@root}") unless inside_root?(path)
    return refuse("#{path} is a webspace root, not one app's directory") unless app_level?(path)
    return refuse("#{path} is a symlink") if File.symlink?(path)
    return refuse("#{path} is not there any more") unless File.directory?(path)
    return refuse("#{path} is also #{@sharer.name}'s path") if shared?(path)

    path
  end

  def refuse(reason)
    @refusal = reason
    nil
  end

  # Prefix match on the SEGMENTS, not the string: "/var/www/vhosts-old/x"
  # starts with "/var/www/vhosts" and is not inside it.
  def inside_root?(path)
    path.start_with?("#{@root}/")
  end

  # <root>/<domain>/<directory> — exactly the shape an app occupies. One
  # segment is a webspace, three or more is something inside an app, and both
  # are somebody else's to delete.
  def app_level?(path)
    path.delete_prefix("#{@root}/").split("/").length == 2
  end

  def shared?(path)
    @sharer = App.where.not(id: app.id).find do |other|
      other_path = other.app_path.to_s
      other_path.present? && File.expand_path(other_path) == path
    end
    @sharer.present?
  end
end
