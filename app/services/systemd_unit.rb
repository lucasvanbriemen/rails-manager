require "erb"

# Renders systemd unit files for the two kinds of long-running process the
# manager owns: an app's own Puma (`ltvb-app@<fqdn>.service`) and a standalone
# worker described by a ProcessService row (Solid Queue, the ActionCable Puma,
# a Laravel queue worker, the Kokoro TTS server).
#
# Root installs and then *executes* whatever comes out of here, so this module is
# a trust boundary in exactly the same sense as deploy/ltvb-deployer. Two rules
# make it one:
#
#   1. Nothing reaches a template unvalidated. Names, users, paths, versions and
#      memory limits must match a narrow pattern or the render raises — it never
#      silently drops the bad part and writes the rest.
#   2. A newline is never escaped, only rejected. systemd parses a unit file line
#      by line, so a stored env value of "x\nExecStartPre=/bin/sh -c curl ..."
#      does not corrupt a value — it adds a root-run command to the unit. There
#      is no quoting that makes that safe, so control characters are refused.
#
# Everything else that *is* escapable is escaped rather than refused, because
# operators legitimately need `$`, `%`, quotes and semicolons in env values.
module SystemdUnit
  # Raised for any input that would produce a unit file we are not willing to
  # hand to root. Callers should surface the message, not rescue it away.
  class Unsafe < StandardError; end

  # Where root reads these from, and the reason it is not this checkout.
  #
  # systemd EXECUTES what comes out of here, as root, deciding which binary runs
  # as which user. The checkout at /var/www/vhosts/ltvb.nl/apps.ltvb.nl is owned
  # by uid 10006 — the uid EIGHT internet-facing apps share — so a template read
  # from `Rails.root` means an RCE in any one of those eight can add an
  # `ExecStartPre=` line to a unit root installs. Validating every value that
  # reaches a template, which the rest of this file is about, is worth nothing
  # when the template itself is attacker input.
  #
  # /etc/ltvb/agent/templates is root-owned and root-installed (see
  # deploy/agent/README.md); every file read out of it is lstat-checked first.
  TEMPLATE_DIR     = Pathname.new("/etc/ltvb/agent/templates/systemd")
  # Development and test only. A production box missing TEMPLATE_DIR raises
  # rather than reaching into the checkout: a silent fallback would restore the
  # hole above the first time someone forgot the install step.
  DEV_TEMPLATE_DIR = Rails.root.join("deploy/templates/systemd")
  UNIT_DIR         = "/etc/systemd/system".freeze

  # Unit files rendered from an App carry RAILS_MASTER_KEY (login.ltvb.nl has no
  # config/master.key on disk at all — Apache's SetEnv was the only copy), and
  # six unrelated webspace users share this box. The installer must use this
  # mode; the template repeats it in a comment so a hand-install gets it right.
  #
  # 0600 is necessary but NOT sufficient: systemd republishes Environment= over
  # D-Bus, so `systemctl show -p Environment <unit>` reveals those values to any
  # local user regardless of the file mode. Moving the secrets to
  # EnvironmentFile= (or LoadCredential=) closes that, and is the reason this
  # constant is named for the file rather than for the secret.
  FILE_MODE = 0o600

  # The system-wide rbenv that replaces the six per-webspace .rbenv trees Plesk's
  # Ruby extension created. Overridable per render: an app that has not been
  # moved off its old webspace rbenv yet still needs a working unit.
  RBENV_ROOT = "/opt/rbenv".freeze

  # One runtime directory per app rather than one shared one, so a compromised
  # app cannot read or replace another app's socket. nginx proxies to the socket
  # inside it and therefore has to be able to traverse it — see the template.
  SOCKET_ROOT = "/run/ltvb-app".freeze
  SOCKET_NAME = "puma.sock".freeze

  # Primary group of all six webspace users (psacln, gid 1003). The three units
  # this replaces already set it, so nothing about file ownership changes.
  DEFAULT_GROUP = "psacln".freeze

  # A Rails app that leaks memory gets OOM-killed and restarted instead of
  # taking the other 21 hostnames down with it.
  DEFAULT_MEMORY_MAX = "1G".freeze

  UNIT_PREFIX = "ltvb-app".freeze

  # --- patterns -------------------------------------------------------------
  # Deliberately narrower than what systemd itself accepts. The manager only
  # ever needs these shapes, and a narrow pattern is the whole reason a value
  # that came out of the database can be trusted in a file root executes.

  # A plain (non-template) unit name: no "@", so a ProcessService can never be
  # made to masquerade as an app instance.
  UNIT_NAME     = /\A[a-z0-9][a-z0-9_-]{0,62}\z/
  # A template instance: an fqdn such as "git.ltvb.nl".
  INSTANCE_NAME = /\A[a-z0-9][a-z0-9.-]{0,126}\z/
  # Plesk webspace owners look like "voordezorgmanagement._rhc4zy0iyc", so dots
  # and underscores are in; 32 characters is the useradd limit.
  USERNAME      = /\A[a-z_][a-z0-9_.-]{0,31}\z/
  ENV_KEY       = /\A[A-Za-z_][A-Za-z0-9_]*\z/
  ABSOLUTE_PATH = %r{\A/[A-Za-z0-9._+@:/-]*\z}
  MEMORY_MAX    = /\A(\d+[KMGT]?|infinity)\z/
  VERSION       = /\A\d+(\.\d+)*\z/

  # Tab is harmless inside a value; every other C0 control (and DEL) either ends
  # the line for systemd's parser or is invisible when auditing the file.
  CONTROL = /[\x00-\x08\x0A-\x1F\x7F]/

  # root would turn "add a background worker" into privilege escalation, which
  # is the one thing this whole bridge exists to prevent.
  FORBIDDEN_USERS = %w[root].freeze

  module_function

  # --- names and paths ------------------------------------------------------

  # "ltvb-app@git.ltvb.nl" — no ".service" suffix, so it can be handed straight
  # to SystemStats.unit_memory_bytes, which appends its own.
  def app_unit_name(app)
    "#{UNIT_PREFIX}@#{instance_name!(app.fqdn)}"
  end

  def app_unit_path(app)
    "#{UNIT_DIR}/#{app_unit_name(app)}.service"
  end

  # Where nginx proxies to. Exposed so the vhost renderer and the unit renderer
  # cannot drift apart — a mismatch here is a 502 with no log line explaining it.
  def app_socket_path(app)
    "#{app_runtime_dir(app)}/#{SOCKET_NAME}"
  end

  def app_runtime_dir(app)
    "#{SOCKET_ROOT}/#{instance_name!(app.fqdn)}"
  end

  def service_unit_path(service)
    "#{UNIT_DIR}/#{unit_name!(service.name)}.service"
  end

  # --- rendering ------------------------------------------------------------

  # The per-app Puma unit. Raises Unsafe rather than emitting a unit for
  # anything that is not a Rails app with a resolvable hostname.
  def render_app(app, memory_max: DEFAULT_MEMORY_MAX, rbenv_root: RBENV_ROOT,
                 group: DEFAULT_GROUP, environment: nil)
    raise Unsafe, "#{app.name} is a #{app.app_kind} app, not a Rails app" unless app.rails_app?

    instance = instance_name!(app.fqdn)
    ruby_bin = ruby_bin_dir!(rbenv_root, app.ruby_version)
    env      = environment || app_environment(app, ruby_bin)

    render "ltvb-app@.service.erb",
           description:       description!("#{instance} Puma"),
           instance:          instance,
           user:              unix_name!(app.deploy_user),
           group:             unix_name!(group, label: "group"),
           working_directory: absolute_path!(app.app_path),
           runtime_directory: "#{File.basename(SOCKET_ROOT)}/#{instance}",
           socket:            app_socket_path(app),
           environment:       environment_lines!(env),
           exec_start:        exec_line!(puma_argv(ruby_bin, app_socket_path(app))),
           memory_max:        memory_max!(memory_max)
  end

  # A plain unit for a ProcessService. Everything comes from the record and
  # nothing is inferred: these processes have almost nothing in common (a python
  # TTS server and a Laravel queue worker share only the idea of a working dir).
  def render_service(service, group: DEFAULT_GROUP, memory_max: nil)
    render "process-service.service.erb",
           description:       description!(service.description_line),
           name:              unit_name!(service.name),
           user:              unix_name!(service.user),
           group:             unix_name!(group, label: "group"),
           working_directory: absolute_path!(service.working_directory),
           environment:       environment_lines!(service.environment),
           exec_start:        exec_line!(service.argv),
           memory_max:        memory_max && memory_max!(memory_max),
           autostart:         service.autostart ? true : false
  end

  # The environment a Puma needs and cannot get from its own checkout.
  # RAILS_MASTER_KEY is the load-bearing entry: login.ltvb.nl has no
  # config/master.key on disk, so once Apache's SetEnv is gone this unit is the
  # only place its key exists. The app's stored .env is merged last, so an
  # operator override in the UI beats these defaults.
  def app_environment(app, ruby_bin)
    env = {
      "RAILS_ENV" => "production",
      "HOME"      => app.webspace_root,
      "PATH"      => "#{ruby_bin}:/usr/local/bin:/usr/bin:/bin"
    }
    env["RAILS_MASTER_KEY"] = app.master_key if app.master_key.present?
    env.merge(parse_env_text(app.env_text))
  end

  # dotenv-style text -> hash. Blank and comment lines are skipped; anything else
  # has to be a well-formed assignment, because quietly dropping half a .env
  # yields an app that boots and then behaves wrongly — worse than a failed
  # render, which at least says which line is broken.
  def parse_env_text(text)
    text.to_s.each_line.filter_map { |raw|
      line = raw.chomp.sub(/\A\s*export\s+/, "").strip
      next if line.empty? || line.start_with?("#")

      key, value = line.split("=", 2)
      raise Unsafe, "malformed env line: #{line.inspect}" if value.nil?

      [ key.strip, unquote(value.strip) ]
    }.to_h
  end

  # --- validation -----------------------------------------------------------

  def unit_name!(name)
    name = name.to_s
    raise Unsafe, "unsafe unit name: #{name.inspect}" unless name.match?(UNIT_NAME)

    name
  end

  def instance_name!(name)
    name = name.to_s
    ok = name.match?(INSTANCE_NAME) && !name.include?("..") && !name.end_with?(".")
    raise Unsafe, "unsafe unit instance: #{name.inspect}" unless ok

    name
  end

  def unix_name!(name, label: "user")
    name = name.to_s
    raise Unsafe, "unsafe #{label} name: #{name.inspect}" unless name.match?(USERNAME)
    raise Unsafe, "refusing to render a unit with #{label} #{name}" if FORBIDDEN_USERS.include?(name)

    name
  end

  def absolute_path!(path)
    path = path.to_s
    ok = path.match?(ABSOLUTE_PATH) && !path.include?("..")
    raise Unsafe, "unsafe absolute path: #{path.inspect}" unless ok

    path
  end

  def memory_max!(value)
    value = value.to_s
    raise Unsafe, "unsafe MemoryMax: #{value.inspect}" unless value.match?(MEMORY_MAX)

    value
  end

  def ruby_bin_dir!(rbenv_root, version)
    version = version.to_s
    raise Unsafe, "unsafe ruby version: #{version.inspect}" unless version.match?(VERSION)

    "#{absolute_path!(rbenv_root)}/versions/#{version}/bin"
  end

  # An argv array, never a command string: with no shell in the picture there is
  # nothing for a `;` or a backtick in a stored value to escape into. A caller
  # that hands us a String gets an error, not a helpfully-split command line.
  def argv!(argv)
    raise Unsafe, "argv must be an array, not #{argv.class}" unless argv.is_a?(Array)
    raise Unsafe, "argv is empty" if argv.empty?

    argv = argv.map(&:to_s)
    argv.each do |arg|
      raise Unsafe, "argv element is blank" if arg.empty?
      raise Unsafe, "argv element contains a control character: #{arg.inspect}" if arg.match?(CONTROL)
      # The one metacharacter that survives quoting: systemd concatenates several
      # command lines in one ExecStart= when a lone ";" appears as its own word,
      # and the word is compared AFTER quotes are stripped. Every other shell
      # character is inert here, so this is the only literal worth refusing.
      raise Unsafe, "argv element is a bare command separator" if arg == ";"
    end
    # An absolute argv[0] means systemd resolves the binary, not a PATH we do not
    # control. systemd insists on this anyway; checking here turns a unit that
    # only fails at start time into a readable error at render time.
    unless argv.first.match?(ABSOLUTE_PATH)
      raise Unsafe, "argv[0] must be an absolute path: #{argv.first.inspect}"
    end

    argv
  end

  def environment!(env)
    raise Unsafe, "environment must be a hash, not #{env.class}" unless env.is_a?(Hash)

    env.to_h do |key, value|
      key   = key.to_s
      value = value.to_s
      raise Unsafe, "unsafe env key: #{key.inspect}" unless key.match?(ENV_KEY)
      raise Unsafe, "env value for #{key} contains a control character" if value.match?(CONTROL)

      [ key, value ]
    end
  end

  # --- escaping -------------------------------------------------------------

  # One `Environment="KEY=value"` payload per entry. The whole assignment is
  # quoted so spaces and `#` survive, and `%` is doubled because systemd expands
  # specifiers (`%h`, `%i`) inside Environment= values.
  def environment_lines!(env)
    environment!(env).map { |key, value| %("#{quote_body("#{key}=#{value}")}") }
  end

  # ExecStart as one absolute binary plus quoted tokens. `$` is doubled on top of
  # the Environment escaping because systemd *does* expand `$FOO` in Exec lines,
  # even inside quotes, and an argument is data — never a variable reference.
  def exec_line!(argv)
    argv!(argv).map { |arg| %("#{quote_body(arg).gsub("$", "$$")}") }.join(" ")
  end

  # Description= is a single line of free text; strip whatever would end it (or
  # hide a second directive behind it) rather than refusing, because it comes
  # from an operator's notes field and is not worth blocking a deploy over.
  def description!(text)
    line = text.to_s.gsub(CONTROL, " ").tr("\t", " ").squeeze(" ").strip[0, 200]
    line = "managed by apps.ltvb.nl" if line.empty?
    line.gsub("%", "%%")
  end

  # --- internals ------------------------------------------------------------

  # Block form, so the replacement string's own backslash escapes never apply.
  # Backslash is handled in the same pass as the quote for the same reason.
  def quote_body(value)
    value.gsub(/[\\"]/) { |char| "\\#{char}" }.gsub("%", "%%")
  end

  def unquote(value)
    quoted = (value.start_with?('"') && value.end_with?('"')) ||
             (value.start_with?("'") && value.end_with?("'"))
    quoted && value.length >= 2 ? value[1..-2] : value
  end

  def puma_argv(ruby_bin, socket)
    # `-b` on the command line replaces the binds from config/puma.rb; without it
    # every app's stock `port ENV.fetch("PORT") { 3000 }` would also open TCP
    # 3000 and only the first app to boot would get it.
    #
    # umask=0007 leaves the socket group-writable so nginx (which has to be a
    # member of the app's group) can connect, while the 0750 runtime directory
    # keeps every other local user out. That matters beyond tidiness:
    # login.ltvb.nl's only protection is an IP allowlist in the vhost, and a
    # world-connectable socket would route straight around it.
    [ "#{ruby_bin}/bundle", "exec", "puma", "-e", "production", "-b", "unix://#{socket}?umask=0007" ]
  end

  # Templates are read per render rather than cached: writing a unit happens once
  # per deploy, and an operator reinstalling a template on the server should not
  # have to restart the manager to see it take effect — nor should a directory
  # that later became writable keep passing a check that ran once at boot.
  def render(template, **values)
    ERB.new(File.read(template_path(template)), trim_mode: "-").result(Context.new(values).binding!)
  end

  def template_path(name)
    dir = installed_template_dir
    return trusted_template!(dir.join(name)) if dir

    unless Rails.env.development? || Rails.env.test?
      raise Unsafe, "#{TEMPLATE_DIR} is not installed; refusing to render unit templates from #{Rails.root} " \
                    "(see the install step in deploy/agent/README.md)"
    end

    DEV_TEMPLATE_DIR.join(name)
  end

  # nil when the directory is simply absent, which is what a development machine
  # looks like. Present-but-untrusted is fatal instead: falling back to the
  # checkout because an attacker managed to chmod a directory would hand them
  # the thing this constant exists to deny.
  def installed_template_dir
    stat = File.lstat(TEMPLATE_DIR)
    unless stat.directory? && stat.uid.zero? && (stat.mode & 0o022).zero?
      raise Unsafe, "#{TEMPLATE_DIR} must be a root-owned directory that nobody else can write"
    end

    TEMPLATE_DIR
  rescue Errno::ENOENT
    nil
  end

  # lstat, not stat. Following the symlink and then asking who owns the
  # destination answers the wrong question: the symlink itself is what an
  # attacker gets to plant, and File::Stat#file? is false for one.
  def trusted_template!(path)
    stat = File.lstat(path)
    unless stat.file? && stat.uid.zero? && (stat.mode & 0o022).zero?
      raise Unsafe, "#{path} must be a plain root-owned file that nobody else can write"
    end

    path
  rescue Errno::ENOENT
    raise Unsafe, "missing unit template #{path}"
  end

  # A bare object holding only pre-validated, pre-escaped strings, so a template
  # cannot reach back into an App or a ProcessService and interpolate something
  # that never went through the checks above.
  class Context
    def initialize(values)
      values.each { |key, value| instance_variable_set(:"@#{key}", value) }
    end

    def binding! = binding
  end
end
