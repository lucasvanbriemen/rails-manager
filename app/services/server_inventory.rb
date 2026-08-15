require "shellwords"

# Turns the Plesk export at /root/plesk-export -- plus the checkouts on disk --
# into App attribute hashes: one per hostname Apache serves, one per cron-only
# Laravel app, and one per abandoned directory left behind in a webspace.
#
# Reading is split from parsing (every parse_* takes text) because none of these
# paths exist on a laptop and /root/plesk-export is 0700 root-only on the
# server. The whole derivation is therefore exercised off-server against the
# captured fixtures in test/fixtures/files/plesk-export/.
#
# What it must not lose, in order of how expensive it would be to rediscover:
#   1. login.ltvb.nl's RAILS_MASTER_KEY. It lives *only* in that vhost's Apache
#      `SetEnv`; there is no config/master.key on disk. Losing the vhost loses
#      the ability to boot the app.
#   2. Which branch is actually checked out. Plesk's psa records drifted from
#      the working copies (it still believes git.ltvb.nl is on `rails-rewrite`).
#   3. That four apps' remotes are gone, so their only copy is a git bundle.
class ServerInventory
  VHOSTS_ROOT = "/var/www/vhosts".freeze

  # The http-01 webroot every certificate on this host actually renews through,
  # read off the server rather than assumed: 20 of the 21 certbot renewal
  # configs are `authenticator = webroot` with this exact `webroot_path`, and
  # each carries a [[webroot_map]] pointing its one domain at the same place.
  # Apache aliases /.well-known/acme-challenge here from every vhost, which is
  # why one shared directory works for 20 unrelated hostnames.
  #
  # Two things about it are traps, both verified on the server:
  #   * it IS dpkg-owned -- `dpkg -S` says plesk-core-utilities owns both
  #     /var/www/vhosts/default and .../htdocs. It survives a purge only because
  #     dpkg will not remove a non-empty directory, and what makes it non-empty
  #     (index.html, .well-known/) is not owned by anything.
  #   * the 21st config, server.ltvb.nl (the panel's own cert), is
  #     `authenticator = apache` + `installer = apache`. It renews through the
  #     web server being replaced, so it breaks the moment Apache stops -- and
  #     nothing in the webroot story covers it.
  ACME_WEBROOT = "/var/www/vhosts/default/htdocs".freeze

  # Every user crontab, concatenated under "# user: <login>" banners. NOT in the
  # export as captured -- see crontab_text.
  CRONTAB_FILE = "crontabs.txt".freeze

  # A concatenation of /etc/letsencrypt/renewal/*.conf. Also not in the export
  # as captured, which is why ACME_WEBROOT above had to be read off the server
  # by hand; optional, so adding it later needs no code change here.
  ACME_RENEWAL_FILE = "serving/certbot-renewal.txt".freeze

  # Stands in for "this checkout exists and we were not allowed to look inside
  # it". An empty marker list used to mean both that and "we looked and found
  # nothing", and the two must never be confused: derive_kind's floor is
  # "static", so a probe that could read nothing classified every Rails and
  # Laravel app on the host as a static site.
  UNREADABLE = "unreadable".freeze

  # Plesk's own scaffolding inside a webspace. `httpdocs` is deliberately NOT
  # here: for an apex domain that directory *is* the site's checkout.
  WEBSPACE_SYSTEM_DIRS = %w[
    anon_ftp bin cgi-bin conf dev error_docs etc git lib lib64 logs
    pd private statistics subdomains tmp usr var
  ].freeze

  # Entries directly under /var/www/vhosts that are not webspaces.
  NON_WEBSPACES = %w[chroot default system].freeze

  # Files whose presence identifies what a checkout is. Precedence lives in
  # derive_kind, not in this list.
  MARKERS = %w[
    Gemfile artisan composer.json index.php index.html
    public/index.php public/index.html .git
  ].freeze

  # Every rails app on this host runs the ltvb webspace's single rbenv build,
  # and every FPM pool is 8.3 -- used only when the checkout can't be read.
  DEFAULT_RUBY_VERSION = "3.3.8".freeze
  DEFAULT_PHP_VERSION  = "8.3".freeze

  # One importable thing. `attributes` is a straight App attribute hash; the
  # rest is advisory -- it explains the row to a human reading the import
  # report, and never reaches the database except through `notes`.
  # `archived` is deliberately a boolean rather than an archived_at timestamp:
  # attributes must be identical on every run so a re-import can tell "nothing
  # changed" from "changed", and the importer owns when the clock is read.
  Entry = Struct.new(:name, :attributes, :archived, :document_root, :plesk_branch,
                     :disk_branch, :remote_status, :flags, :probe_failed, keyword_init: true) do
    def app_kind = attributes[:app_kind]
    def archived? = !!archived
    def apex? = attributes[:serves_http] && attributes[:subdomain].blank?

    # The disk probe saw nothing here. Everything derived from the checkout --
    # app_kind, ruby_version, and primary_db_kind through app_kind -- is a
    # fallback guess on this entry, not a measurement.
    def probe_failed? = !!probe_failed

    def fqdn
      [ attributes[:subdomain], attributes[:domain] ].reject(&:blank?).join(".")
    end

    # Identity for finding the App row this entry already has. Hostname apps are
    # their name in DNS; repos and orphans have no hostname, so they are the
    # place their code sits.
    def match_key = attributes[:deploy_path].presence || fqdn
  end

  # The same key, computed from a persisted App. Kept next to Entry#match_key so
  # the two can never drift apart.
  def self.match_key_for(app)
    app.deploy_path.presence || [ app.subdomain, app.domain ].reject(&:blank?).join(".")
  end

  # Kind derivation reads the checkout itself -- Plesk's records say what it
  # deploys, never what the code is. Injected because the webspaces are 0750
  # owner:psaserv: tests use MarkerDisk, and so can an operator who captured
  # the probe as root but runs the import as `ltvb`.
  class LiveDisk
    def children(path)
      Dir.children(path).select { |name| File.directory?(File.join(path, name)) }
    rescue SystemCallError
      []
    end

    # Dir.children does double duty: it is the php scan AND the readability
    # probe. File.exist? cannot be the probe -- it answers false for a file
    # inside a 0750 directory we may not traverse, exactly as it does for a file
    # that is not there, and that is how a permission problem became a
    # classification. EACCES and ENOENT are told apart here so the caller can
    # refuse to act on the first while still recording the second.
    def markers(path)
      names = Dir.children(path)
      found = MARKERS.select { |marker| File.exist?(File.join(path, marker)) }
      found << "php-files" if names.any? { |name| name.end_with?(".php") }
      version = ruby_version(path)
      found << "ruby=#{version}" if version.present?
      found
    rescue Errno::ENOENT, Errno::ENOTDIR
      []
    rescue SystemCallError
      [ UNREADABLE ]
    end

    private

    def ruby_version(path)
      File.read(File.join(path, ".ruby-version")).strip
    rescue SystemCallError
      nil
    end
  end

  # The same probe replayed from a captured TSV (`path<TAB>marker,marker,...`).
  class MarkerDisk
    def initialize(text)
      @markers  = {}
      @children = {}
      text.to_s.each_line do |line|
        path, markers = line.chomp.split("\t", 2)
        next if path.blank? || path == "path"

        @markers[path] = markers.to_s.split(",").reject(&:blank?)
        register(path)
      end
    end

    def children(path) = @children.fetch(path, [])
    def markers(path)  = @markers.fetch(path, [])

    private

    # A flat list of leaf paths still has to answer "what is in this directory",
    # so every ancestor is registered on the way up.
    def register(path)
      while path != "/" && path != "."
        parent = File.dirname(path)
        list = (@children[parent] ||= [])
        list << File.basename(path) unless list.include?(File.basename(path))
        path = parent
      end
    end
  end

  # claimed_paths: checkouts an existing App already owns. Without them the
  # ui-components repo (a live, tracked App with no vhost) looks exactly like an
  # abandoned directory and would be imported a second time, archived.
  def initialize(export_dir:, disk: LiveDisk.new, crontabs: nil, claimed_paths: [])
    @export_dir    = export_dir.to_s
    @disk          = disk
    @crontabs      = crontabs
    @claimed_paths = claimed_paths.map { |path| path.to_s.chomp("/") }
    @warnings      = []
  end

  attr_reader :warnings

  def entries
    @entries ||= served_entries + cron_entries + orphan_entries
  end

  # Every crontab line on the host as ScheduledJob attributes. Deliberately not
  # folded into `entries`: a cron line is not an app, four of the nine here run
  # something that is not one, and the import adopts them read-only rather than
  # writing them.
  def scheduled_jobs
    @scheduled_jobs ||= self.class.parse_crontabs(crontab_text)
  end

  # Cron lines the manager could not turn into an argv array -- a pipe, an
  # unbalanced quote, a second `&&`. Reported rather than dropped: a job nobody
  # can model is exactly the one that stops running unnoticed.
  def unmodellable_jobs
    scheduled_jobs.select { |job| job[:argv].empty? }
  end

  # Where http-01 challenges are actually served from. Read from the export when
  # a renewal-config capture is there, and otherwise the value verified on the
  # server. NginxConfig renders the same constant, so a vhost cannot advertise a
  # challenge path that renewal does not write into.
  def acme_webroot
    @acme_webroot ||= self.class.parse_acme_webroot(read_optional(ACME_RENEWAL_FILE)) || ACME_WEBROOT
  end

  # ---- parsers (pure; take file contents) ----------------------------------

  # Header row + tab-separated rows => [{ column => value }]. split(-1) keeps
  # trailing empty fields, which is how "no post-deploy script" is spelled.
  def self.parse_tsv(text)
    lines = text.to_s.each_line.map(&:chomp).reject(&:empty?)
    header = lines.shift.to_s.split("\t", -1)
    lines.map { |line| header.zip(line.split("\t", -1)).to_h }
  end

  # The dump of hand-written vhost.conf/vhost_ssl.conf overrides, keyed by the
  # "HOST: <fqdn>" banners it is grouped under => { fqdn => { VAR => value } }.
  # Apache SetEnv is the only place some of these values exist.
  def self.parse_set_envs(text)
    host = nil
    text.to_s.each_line.with_object({}) do |line, envs|
      if (match = line.match(/^HOST:\s*(\S+)/))
        host = match[1]
      elsif host && (match = line.match(/^\s*SetEnv\s+(\S+)\s+(\S+)/))
        (envs[host] ||= {})[match[1]] = match[2]
      end
    end
  end

  # "Require ip 1.2.3.4 ::1" => "1.2.3.4 ::1"; anything else => nil.
  def self.parse_allowlist(text)
    return nil if text.blank? || text == "none"

    text.sub(/\ARequire\s+ip\s+/, "").split.join(" ").presence
  end

  # certbot renewal configs => the single webroot they all challenge through, or
  # nil if they disagree (in which case there is no "the" webroot and one shared
  # nginx location cannot serve them). `webroot_path` is a comma-separated list
  # and certbot writes it with a trailing comma, so the empty tail is dropped.
  # `authenticator = apache` configs have no webroot at all and are ignored here
  # -- they are a separate problem, and a louder one.
  def self.parse_acme_webroot(text)
    paths = text.to_s.each_line.filter_map { |line|
      match = line.match(/^\s*webroot_path\s*=\s*(.+)$/)
      match && match[1].split(",").map(&:strip).reject(&:blank?)
    }.flatten.uniq

    paths.one? ? paths.first : nil
  end

  # Crontab text (any number of users concatenated) => the app directories that
  # run a Laravel scheduler. Two spellings are in use on this host:
  #   * * * * * cd /path/to/app && php artisan schedule:run
  #   * * * * * /usr/bin/php '/path/to/app/artisan' 'schedule:run'
  def self.parse_cron_apps(text)
    text.to_s.each_line.filter_map do |line|
      next unless line.include?("schedule:run")
      next if line.strip.start_with?("#")

      if (match = line.match(%r{['"]?(/\S*?)/artisan['"]?}))
        match[1]
      elsif (match = line.match(%r{cd\s+['"]?(/\S+?)['"]?\s+&&}))
        match[1]
      end
    end.uniq
  end

  # Crontab text => one ScheduledJob attribute hash per real job line. The input
  # is every user's crontab concatenated under "# user: <login>" banners.
  #
  # Nine job lines exist on this host, spread over five users, and between them
  # they use every shape this has to survive:
  #
  #   * * * * * cd <dir> && php artisan schedule:run >> /dev/null 2>&1
  #   * * * * * /usr/bin/php '<dir>/artisan' 'schedule:run'
  #   0 * * * * /opt/psa/admin/sbin/fetch_url 'https://.../send-mail.php'
  #   0 0 * * * python3 <dir>/cron/get_users/main.py
  #   * * * * * /usr/local/bin/rails-deploy-watch.sh                     (root)
  #
  # argv comes out of Shellwords, never a command string, and the shell parts of
  # the line (`cd ... &&`, the /dev/null redirect) become their own fields -- a
  # ScheduledJob is run without a shell, so anything that needed one has to be
  # represented rather than embedded.
  def self.parse_crontabs(text)
    user  = nil
    env   = {}
    names = Hash.new(0)

    text.to_s.each_line.filter_map do |raw|
      line = raw.chomp
      if (match = line.match(/\A#\s*user:\s*(\S+)/))
        user, env = match[1], {}
        next
      end
      next if line.strip.empty? || line.lstrip.start_with?("#")
      # MAILTO="" and SHELL="/bin/bash" are per-crontab settings that apply to
      # every line below them, and MAILTO in particular is why nobody notices
      # when one of these jobs starts failing.
      if (match = line.match(/\A\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\z/))
        env[match[1]] = match[2].strip.delete_prefix('"').delete_suffix('"')
        next
      end

      job = parse_cron_line(line, user: user, environment: env.dup)
      next unless job

      # Derived names must be unique or two jobs collide on the unique index.
      names[job[:name]] += 1
      job[:name] = "#{job[:name]}-#{names[job[:name]]}" if names[job[:name]] > 1
      job
    end
  end

  # Five whitespace-separated fields (or an @macro) and then the command, taken
  # from the original line so its quoting survives to Shellwords intact.
  CRON_LINE = /\A\s*(@\w+|\S+(?:\s+\S+){4})\s+(.+)\z/

  def self.parse_cron_line(line, user:, environment: {})
    match = line.match(CRON_LINE)
    return nil unless match

    schedule = match[1].split(/\s+/).join(" ")
    directory, command, discard = split_cron_command(match[2])
    argv = shell_split(command)

    # managed: false because a parsed line describes something cron is already
    # running. Adopting it read-only is the only honest thing to do with it; the
    # decision to take a job over is separate and per-job.
    { name: job_name(user: user, argv: argv, working_directory: directory),
      user: user, cron_schedule: schedule, argv: argv, working_directory: directory,
      environment: environment, discard_output: discard, managed: false, raw: line.strip }
  end

  # Peels the shell off a cron command. `cd <dir> && ...` is how one of the four
  # schedulers is spelled, and that same line is the one ending
  # `>> /dev/null 2>&1`. Neither is an argument: treating them as arguments puts
  # a literal ">>" in argv and loses the directory the job has to run in.
  def self.split_cron_command(command)
    # An unescaped % ends a cron command -- everything after it is fed to the job
    # on stdin. No line here uses one, but reading stdin as argv would be silent
    # and wrong, so the command is cut there.
    rest = command.to_s.split(/(?<!\\)%/, 2).first.to_s.strip
    directory = nil

    if (match = rest.match(/\Acd\s+('[^']*'|"[^"]*"|\S+)\s*&&\s*(.+)\z/))
      directory = match[1].delete_prefix("'").delete_suffix("'").delete_prefix('"').delete_suffix('"')
      rest = match[2]
    end

    discard = false
    if (match = rest.match(%r{\s*(?:1?>>?|&>)\s*/dev/null(?:\s+2>&1)?\s*\z}))
      discard = true
      rest = rest[0...match.begin(0)].to_s
    end

    [ directory.presence, rest.strip, discard ]
  end

  # Shell operators Shellwords happily returns as ordinary words. `foo | bar`
  # comes back as three arguments, and argv has no way to express a pipeline --
  # so a line containing one is reported empty rather than half-parsed into
  # something that would run differently from what cron runs today.
  SHELL_OPERATORS = %w[| || & && ; ;; > >> < << 2>&1].freeze
  SUBSTITUTION    = /[`]|\$\(/

  def self.shell_split(command)
    argv = Shellwords.split(command.to_s)
    return [] if argv.any? { |word| SHELL_OPERATORS.include?(word) || word.match?(SUBSTITUTION) }

    argv
  rescue ArgumentError
    []
  end

  # Cron lines have no names and a ScheduledJob needs one, so it is derived --
  # deterministically, because a name that moved between runs would adopt the
  # same line twice. Built from the app directory the job touches (the only
  # durable thing about it) and the tail of the command, which is what tells
  # rijschool's three otherwise identical python jobs apart.
  def self.job_name(user:, argv:, working_directory: nil)
    target = [ working_directory, *argv ].compact.find { |value| value.to_s.start_with?("#{VHOSTS_ROOT}/") }
    base   = target ? app_dir_name(target) : user
    slugify([ base, command_tail(argv) ].reject(&:blank?).join("-"))
  end

  # ".../vhosts/lucasvanbriemen.nl/calendar.lucasvanbriemen.nl/artisan" =>
  # "calendar.lucasvanbriemen.nl": the app directory, two levels under the root.
  def self.app_dir_name(path)
    path.to_s.delete_prefix("#{VHOSTS_ROOT}/").split("/")[1].to_s
  end

  # The last two segments of the final argument, minus any extension:
  # "cron/get_users/main.py" => "get_users-main", "schedule:run" => "schedule:run".
  def self.command_tail(argv)
    Array(argv).last.to_s.sub(/\.\w+\z/, "").split("/").last(2).join("-")
  end

  def self.slugify(text)
    text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")[0, 63]
  end

  # Plesk stores post-deploy scripts with literal backslash-n between lines.
  def self.unescape_script(text)
    text.to_s.gsub("\\n", "\n")
  end

  # Plesk's post-deploy scripts are imported only when they are genuinely a list
  # of commands for *this* app. Two ways they are not, both present on this host:
  #
  #   * mail.ltvb.nl and git.ltvb.nl carry a verbatim copy of login.ltvb.nl's
  #     script -- it cds into login's directory and bundles there. Importing it
  #     would make deploying mail rebuild login.
  #   * Those scripts are shell programs (shebang, `set -euo pipefail`, a trap).
  #     App#post_deploy_command_list runs each line in its own shell, so a
  #     program decomposed into lines is not the same program.
  #
  # Rejected scripts are kept verbatim in the App's notes instead of run.
  def self.safe_post_deploy_commands(script, app_dir)
    body = unescape_script(script)
    return [] if body.strip.empty?
    return [] if body.lstrip.start_with?("#!")

    commands = body.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
    foreign = commands.any? do |command|
      command.scan(%r{#{Regexp.escape(VHOSTS_ROOT)}/\S+}).any? { |path| !path.start_with?(app_dir) }
    end
    foreign ? [] : commands
  end

  # A served host's document root is the checkout, or the checkout's public/.
  def self.checkout_dir(document_root)
    document_root.to_s.chomp("/").sub(%r{/public\z}, "")
  end

  # fqdn + the webspace its files live in => [subdomain, domain]. The webspace
  # directory is the authority: "mos-safeguards.com" is an apex site (nil
  # subdomain), "admin.mos-safeguards.com" is a subdomain of it. Falls back to
  # splitting off the first label for hosts served from outside a webspace
  # (Plesk's own Roundcube), which is right for both webmail hostnames.
  def self.split_host(fqdn, webspace)
    return [ nil, fqdn ] if webspace.present? && fqdn == webspace
    return [ fqdn.sub(/\.#{Regexp.escape(webspace)}\z/, ""), webspace ] if webspace.present?

    first, rest = fqdn.split(".", 2)
    rest.present? ? [ first, rest ] : [ nil, fqdn ]
  end

  # What the code is, from the checkout. Falls back to how Apache serves it,
  # which is all that is left when the checkout is not readable.
  def self.derive_kind(markers, cron: false, passenger: false, public_docroot: false)
    return "rails" if markers.include?("Gemfile")
    return cron ? "cron" : "laravel" if markers.include?("artisan")
    return "php" if (markers & %w[composer.json index.php public/index.php php-files]).any?
    return "static" if markers.include?("index.html")
    return "rails" if passenger

    public_docroot ? "laravel" : "static"
  end

  # An empty marker list is not a classification, it is a failed measurement.
  # derive_kind still has to answer something for it (Apache's config is a real,
  # if weak, source), but nothing derived from it may be written over a value an
  # earlier, working probe established. UNREADABLE says the same thing with the
  # cause attached.
  def self.probe_failed?(markers)
    markers.empty? || markers.include?(UNREADABLE)
  end

  # ".ruby-version" holds "ruby-3.3.8" here; App wants "3.3.8".
  def self.normalize_ruby_version(marker)
    marker.to_s.sub(/\Aruby=/, "").sub(/\Aruby-/, "").presence
  end

  private

  # ---- entry builders ------------------------------------------------------

  def served_entries
    vhost_rows.map do |row|
      fqdn      = row["fqdn"]
      docroot   = row["document_root"].to_s
      app_dir   = self.class.checkout_dir(docroot)
      public_dr = app_dir != docroot.chomp("/")
      behaviour = behaviours[fqdn] || {}
      markers   = @disk.markers(app_dir)
      kind      = self.class.derive_kind(markers, passenger: behaviour["passenger"] == "yes",
                                                  public_docroot: public_dr)
      subdomain, domain = self.class.split_host(fqdn, webspace_of(app_dir))

      build_entry(
        name: fqdn, app_dir: app_dir, document_root: docroot, markers: markers,
        app_kind: kind, subdomain: subdomain, domain: domain,
        doc_root_suffix: public_dr ? "public" : "",
        runtime_user: row["suexec_user_group"].to_s.split(":").first,
        serves_http: true, probe_failed: self.class.probe_failed?(markers),
        ip_allowlist: self.class.parse_allowlist(behaviour["ip_allowlist"]),
        hsts: behaviour["hsts_header"].present? && behaviour["hsts_header"] != "none",
        set_env: set_envs[fqdn] || {}
      )
    end
  end

  # Laravel apps with a scheduler entry but no vhost. Their directory is named
  # like a hostname that was never published, so subdomain/domain still resolve
  # App#app_path to the right place.
  def cron_entries
    served = vhost_rows.map { |row| self.class.checkout_dir(row["document_root"]) }

    self.class.parse_cron_apps(crontab_text).reject { |dir| served.include?(dir) }.map do |app_dir|
      subdomain, domain = self.class.split_host(File.basename(app_dir), webspace_of(app_dir))

      markers = @disk.markers(app_dir)

      build_entry(
        name: File.basename(app_dir), app_dir: app_dir, document_root: nil,
        markers: markers, app_kind: self.class.derive_kind(markers, cron: true),
        subdomain: subdomain, domain: domain, doc_root_suffix: "",
        runtime_user: webspace_owners[webspace_root_of(app_dir)], serves_http: false,
        probe_failed: self.class.probe_failed?(markers),
        extra_flags: [ "cron-only: a Laravel scheduler runs it, no vhost serves it" ]
      )
    end
  end

  # Directories in a webspace that nothing serves, nothing schedules, and no
  # App claims. They are imported archived rather than skipped: an unexplained
  # directory found later during the Plesk teardown is indistinguishable from a
  # site someone forgot to migrate.
  def orphan_entries
    accounted = vhost_rows.map { |row| self.class.checkout_dir(row["document_root"]) } +
                self.class.parse_cron_apps(crontab_text) + @claimed_paths

    webspace_roots.flat_map do |root|
      @disk.children(root).sort.filter_map do |name|
        next if name.start_with?(".") || WEBSPACE_SYSTEM_DIRS.include?(name)

        app_dir = File.join(root, name)
        next if accounted.include?(app_dir)

        # An orphan's kind is "repo" whatever the probe saw, so an empty marker
        # list costs nothing here -- an abandoned directory with nothing in it
        # is an ordinary thing to find. Only an outright unreadable one is a
        # failed measurement.
        markers = @disk.markers(app_dir)

        # A repo has no hostname and an explicit path, which is exactly the
        # shape of an abandoned directory -- and the only App kind that can
        # carry an absolute path without inventing a subdomain for it.
        build_entry(
          name: "#{File.basename(root)}/#{name}", app_dir: app_dir, document_root: nil,
          markers: markers, app_kind: "repo", subdomain: nil, domain: nil,
          doc_root_suffix: "", runtime_user: webspace_owners[root], serves_http: false,
          deploy_path: app_dir, archived: true, probe_failed: markers.include?(UNREADABLE),
          extra_flags: [ "abandoned: nothing serves or schedules this directory" ]
        )
      end
    end
  end

  # Notes are assembled deterministically -- no timestamps, no run-dependent
  # text -- so re-importing an unchanged server produces byte-identical notes
  # and the task reports "unchanged" instead of a phantom diff.
  def build_entry(name:, app_dir:, document_root:, markers:, app_kind:, subdomain:, domain:,
                  doc_root_suffix:, runtime_user:, serves_http:, probe_failed:, ip_allowlist: nil,
                  hsts: false, set_env: {}, deploy_path: nil, archived: false, extra_flags: [])
    git   = git_facts(app_dir)
    flags = extra_flags + git[:flags]
    notes = [ "checkout: #{app_dir}" ]
    notes << "document root: #{document_root}" if document_root.present?

    if probe_failed
      cause = markers.include?(UNREADABLE) ? "permission denied" : "no marker file was found"
      flags << "checkout not readable: the disk probe saw nothing in #{app_dir} (#{cause}), so " \
               "app_kind=#{app_kind}, ruby_version and php_version are fallbacks, not measurements"
    end
    if document_root.present? && !document_root.start_with?(VHOSTS_ROOT)
      flags << "document root is outside #{VHOSTS_ROOT} (Plesk-owned); App#app_path will not match it"
    end
    if set_env["RAILS_MASTER_KEY"].present?
      flags << "RAILS_MASTER_KEY rescued from Apache SetEnv -- the app has no config/master.key"
    end
    if git[:rejected_script].present?
      notes << "Plesk post-deploy script (NOT imported -- see flags):\n#{git[:rejected_script]}"
    end
    notes.concat(git[:notes])

    Entry.new(
      name: name,
      archived: archived,
      document_root: document_root,
      plesk_branch: git[:plesk_branch],
      disk_branch: git[:disk_branch],
      remote_status: git[:remote_status],
      flags: flags,
      probe_failed: probe_failed,
      attributes: {
        name: name,
        app_kind: app_kind,
        subdomain: subdomain,
        domain: domain,
        runtime_user: runtime_user.presence,
        doc_root_suffix: doc_root_suffix,
        serves_http: serves_http,
        deploy_path: deploy_path,
        ruby_version: ruby_version_from(markers),
        php_version: php_version_for(name),
        primary_db_kind: App::PHP_KINDS.include?(app_kind) ? "external" : "sqlite",
        ip_allowlist: ip_allowlist,
        hsts: hsts,
        git_repo_url: git[:url],
        git_branch: git[:branch],
        post_deploy_commands: git[:commands].join("\n").presence,
        master_key: set_env["RAILS_MASTER_KEY"],
        env_text: set_env.map { |key, value| "#{key}=#{value}" }.join("\n").presence,
        # Arming a webhook is a per-app decision, never a side effect of an
        # inventory sweep: 25 apps redeploying on push is not a migration plan.
        auto_deploy: false,
        notes: notes.join("\n")
      }
    )
  end

  # ---- git ------------------------------------------------------------------

  # Reconciles three sources that disagree: Plesk's psa records, the working
  # copy, and the reachability probe. The working copy wins -- it is what is
  # actually being served -- and every disagreement is flagged rather than
  # silently resolved.
  def git_facts(app_dir)
    plesk  = plesk_repos.find { |row| row["deployment_path_abs"].to_s.chomp("/") == app_dir }
    disk   = ondisk_repos.find { |row| row["path"].to_s.chomp("/") == app_dir }
    flags  = []
    notes  = []

    plesk_branch = plesk&.dig("branch").presence
    disk_branch  = disk&.dig("branch").presence
    if plesk_branch && disk_branch && plesk_branch != disk_branch
      flags << "branch divergence: Plesk records #{plesk_branch}, the checkout is on " \
               "#{disk_branch} -- importing #{disk_branch}"
    end

    url, url_flag, url_note = git_url(app_dir, plesk, disk)
    flags << url_flag if url_flag
    # A bundle only exists for a repo whose remote is gone, so its presence is
    # itself the alarm -- it belongs in the report, not just the stored notes.
    if url_note
      notes << url_note
      flags << url_note
    end

    # PUSH_MODE_NO_REMOTE is not a failure -- git_url already explains it.
    status = plesk && reachability[plesk["repo_id"]]&.dig("status")
    if status.present? && !%w[REACHABLE PUSH_MODE_NO_REMOTE].include?(status)
      flags << "git remote #{status}: #{plesk['fetch_url'].presence || '(none)'} -- " \
               "the only remaining copy is the checkout and the recovery bundle"
    end

    script   = plesk&.dig("post_deploy_script_escaped").to_s
    commands = self.class.safe_post_deploy_commands(script, app_dir)
    rejected = nil
    if script.strip.present? && commands.empty?
      rejected = self.class.unescape_script(script)
      flags << "Plesk post-deploy script not imported (#{reject_reason(rejected, app_dir)}) -- " \
               "kept verbatim in notes"
    end

    { url: url, branch: disk_branch || plesk_branch || "main", plesk_branch: plesk_branch,
      disk_branch: disk_branch, remote_status: status, commands: commands,
      rejected_script: rejected, flags: flags, notes: notes }
  end

  # The on-disk remote is the truth about where the code came from. Plesk's
  # fetch_url is next. After that there is no remote at all, and the fallbacks
  # exist so the row can still be saved (App requires git_repo_url) while
  # pointing at something real: the push-mode bare repo, or the directory
  # itself. A bad clone URL fails loudly; a missing App row fails silently.
  def git_url(app_dir, plesk, disk)
    if disk && disk["remote_origin_url"].present?
      [ disk["remote_origin_url"], nil, nil ]
    elsif plesk && plesk["fetch_url"].present?
      [ plesk["fetch_url"], nil, bundle_note(plesk) ]
    elsif plesk && plesk["bare_repo_path"].present?
      [ plesk["bare_repo_path"],
        "push-mode repo: the bare repo on this server IS the origin, there is no upstream",
        bundle_note(plesk) ]
    else
      [ app_dir, "not under git: git_repo_url is the on-disk path, so nothing can clone it", nil ]
    end
  end

  # The rescue copy for repos whose remote is gone.
  def bundle_note(plesk)
    name   = plesk["repo_name"].to_s.sub(/\.git\z/, "")
    bundle = bundles.find { |path| File.basename(path, ".bundle") == name }
    "recovery bundle: #{bundle}" if bundle
  end

  # Which of safe_post_deploy_commands' two rules rejected this script. Told
  # apart so the report says whether the script is salvageable by hand (a shell
  # program) or is simply the wrong app's (a copy-paste that must not be kept).
  def reject_reason(script, app_dir)
    return "shell program, not a command list" if script.lstrip.start_with?("#!")

    "it operates on another app's directory, not #{app_dir}"
  end

  # ---- sources --------------------------------------------------------------

  def vhost_rows   = @vhost_rows ||= self.class.parse_tsv(read("serving/vhost-summary.tsv"))
  def plesk_repos  = @plesk_repos ||= self.class.parse_tsv(read("git-repos.tsv"))
  def ondisk_repos = @ondisk_repos ||= self.class.parse_tsv(read("ondisk-git-state.tsv"))
  def set_envs     = @set_envs ||= self.class.parse_set_envs(read("serving/custom-vhost-overrides.txt"))
  def bundles      = @bundles ||= Dir.glob(File.join(@export_dir, "at-risk-repos", "*.bundle")).sort

  def behaviours
    @behaviours ||= self.class.parse_tsv(read("serving/serving-behaviours.tsv"))
                        .index_by { |row| row["fqdn"] }
  end

  def reachability
    @reachability ||= self.class.parse_tsv(read("git-remote-reachability.tsv"))
                          .index_by { |row| row["repo_id"] }
  end

  # fqdn => php version, from the per-domain FPM pool. Plesk names each pool
  # after the host it serves, so the pool named "www" (the distro default) is
  # not one of ours.
  def fpm_versions
    @fpm_versions ||= self.class.parse_tsv(read("serving/fpm-pools.tsv"))
                          .reject { |row| row["pool_name"] == "www" }
                          .to_h { |row| [ row["pool_name"], row["php_version"] ] }
  end

  # webspace root path => the system user that owns it.
  def webspace_owners
    @webspace_owners ||= self.class.parse_tsv(read("serving/webspace-users.tsv"))
                             .to_h { |row| [ row["home"], row["login"] ] }
  end

  # The export does NOT contain crontabs.txt. Checked on the server: it holds
  # git-deploy-scripts/root-crontab.txt (root's only) and nothing else, so an
  # import run against it silently drops three of the 25 apps -- ai.ltvb.nl,
  # calendar. and email.lucasvanbriemen.nl exist solely because of a crontab
  # line -- along with every other scheduled job on the host. The warning has to
  # say what was lost, not just which file was missing, because a missing file
  # produces no rows and no rows looks exactly like nothing to do.
  def crontab_text
    return @crontab_text if defined?(@crontab_text)

    @crontab_text = @crontabs || read_crontabs
  end

  def read_crontabs
    path = File.join(@export_dir, CRONTAB_FILE)
    return File.read(path) if File.readable?(path)

    @warnings << "#{CRONTAB_FILE} is not in the export: every cron-only app and every " \
                 "scheduled job is invisible to this run. Capture it with " \
                 "`for u in $(cut -d: -f1 /etc/passwd); do crontab -l -u $u; done` (banner each " \
                 "user as \"# user: <login>\") and re-run with CRONTABS=<file>."
    ""
  end

  def webspace_roots
    @webspace_roots ||= @disk.children(VHOSTS_ROOT).sort
                             .reject { |name| name.start_with?(".") || NON_WEBSPACES.include?(name) }
                             .map { |name| File.join(VHOSTS_ROOT, name) }
  end

  # ---- helpers --------------------------------------------------------------

  # "/var/www/vhosts/ltvb.nl/git.ltvb.nl" => "ltvb.nl"; nil for anything served
  # from outside the webspaces.
  def webspace_of(path)
    return nil unless path.to_s.start_with?("#{VHOSTS_ROOT}/")

    path.to_s.delete_prefix("#{VHOSTS_ROOT}/").split("/").first
  end

  # The same thing as an absolute path, which is how webspace-users.tsv keys
  # its owners (the login's home directory).
  def webspace_root_of(path)
    webspace = webspace_of(path)
    File.join(VHOSTS_ROOT, webspace) if webspace
  end

  def ruby_version_from(markers)
    marker = markers.find { |m| m.start_with?("ruby=") }
    self.class.normalize_ruby_version(marker) || DEFAULT_RUBY_VERSION
  end

  def php_version_for(fqdn)
    fpm_versions[fqdn] || DEFAULT_PHP_VERSION
  end

  def read(relative_path)
    File.read(File.join(@export_dir, relative_path))
  rescue SystemCallError => e
    @warnings << "could not read #{relative_path}: #{e.message}"
    ""
  end

  # For files the export is not expected to have yet. Absence is the normal case
  # and carries its own documented fallback, so it is not a warning.
  def read_optional(relative_path)
    path = File.join(@export_dir, relative_path)
    File.readable?(path) ? File.read(path) : ""
  end
end
