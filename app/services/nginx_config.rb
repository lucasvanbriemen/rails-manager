require "erb"
require "ipaddr"

# Previews and validates the nginx `server` blocks that replace an App's
# Plesk-generated Apache vhost.
#
# This class does NOT own the config text and does not write files. The agent
# writes them, root-side, from /etc/ltvb/agent/templates/nginx-site.erb; this
# renders THAT SAME FILE with THAT SAME variable set, so a preview here is the
# bytes the agent installs and a test failure here means the served config is
# wrong. There used to be a second template set under this checkout, and it
# drifted: the index-precedence fix landed on it and had no effect on anything
# served, while two of the three PHP sites kept `index index.php index.html`.
#
# The output is parsed by root. nginx reads it with full privilege, so a single
# smuggled `;` or `}` in a record field would let whoever can edit an App add
# arbitrary directives — proxy_pass somewhere else, alias / into the config, run
# a different php-fpm pool. Every value that reaches the template therefore goes
# through the validators below, and there is deliberately NO free-text
# "extra nginx config" field: the four customisations this server actually needs
# (websocket cable, IP allowlist, X-Accel-Redirect, HSTS) are typed fields the
# template branches on. A fifth one becomes a fifth typed field, reviewed once,
# here — not a textarea.
class NginxConfig
  # Raised instead of rendering. Callers must treat this as "do not write a
  # file"; a partially-rendered config is a config nginx refuses to load, which
  # takes down every site on the box, not just this one.
  class UnsafeValue < StandardError; end

  # The agent's template directory, and the reason it is not this checkout.
  #
  # nginx parses the output of this template with full privilege. The checkout
  # at /var/www/vhosts/ltvb.nl/apps.ltvb.nl is owned by uid 10006 — the uid EIGHT
  # internet-facing apps share — so a template read from `Rails.root` means an
  # RCE in any one of those eight rewrites a file root then parses: proxy_pass
  # somewhere else, alias / into the config, a different fastcgi pool. That is a
  # full privilege escalation, and no amount of validating the values
  # interpolated INTO a template helps when the template itself is the input.
  #
  # This is deliberately the agent's OWN directory, flat and unqualified, rather
  # than a nginx/ subdirectory beside it: the agent resolves a template by a bare
  # name under exactly this path, and pointing the two at the same file is what
  # makes this class a preview instead of a second opinion.
  TEMPLATE_DIR     = Pathname.new("/etc/ltvb/agent/templates")
  # Development and test only. Never reached in production — a production box
  # missing TEMPLATE_DIR raises instead of falling back into the checkout,
  # because a silent fallback would restore exactly the hole above the first
  # time someone forgot the install step.
  DEV_TEMPLATE_DIR = Rails.root.join("deploy/templates/nginx")

  # Live ports are Apache's today; staging runs the identical block beside it so
  # the whole cutover can be tested with real certificates and real traffic
  # shapes before anything is switched over.
  LIVE_PORTS    = { http: 80,   https: 443  }.freeze
  STAGING_PORTS = { http: 9080, https: 9443 }.freeze

  CERT_ROOT       = "/etc/letsencrypt/live".freeze
  LOG_ROOT        = "/var/log/ltvb/sites".freeze
  # Must match SystemdUnit::SOCKET_ROOT/SOCKET_NAME — that is what actually
  # creates the socket (RuntimeDirectory=ltvb-app/<fqdn>, mode 0750, one
  # directory per app). Duplicated rather than referenced so rendering a vhost
  # does not depend on loading the unit renderer; the test asserts they agree.
  SOCKET_ROOT     = "/run/ltvb-app".freeze
  SOCKET_NAME     = "puma.sock".freeze
  # Plesk's per-domain php-fpm pools; kept as-is so the pool files do not have
  # to move in the same change that moves the web server.
  FPM_SOCKET_ROOT = "/var/www/vhosts/system".freeze
  # One shared webroot for http-01 challenges, so renewal does not depend on any
  # individual site's document root existing or being readable.
  #
  # This is NOT a free choice: all 20 certbot lineages already carry
  # `webroot_path = /var/www/vhosts/default/htdocs` in their renewal configs
  # (Apache aliases /.well-known/acme-challenge there from every vhost, which is
  # why issuing against an app's own docroot 404s). Rendering a different path
  # here would 404 every http-01 challenge after cutover and silently break
  # renewal for all 20 sites ~30 days later. The directory is not dpkg-owned, so
  # it survives the Plesk removal. Changing it means rewriting webroot_path and
  # [[webroot_map]] in all 20 renewal configs in the same change.
  ACME_WEBROOT    = "/var/www/vhosts/default/htdocs".freeze

  # Apache's XSendFile takes a filesystem path; nginx's X-Accel-Redirect takes a
  # URI. This is the URI namespace an app sends paths under.
  XACCEL_LOCATION = "/_x-accel/".freeze

  # 182.5 days — the value lucasvanbriemen.nl already sends. Lowering it would
  # not take effect for anyone who has already pinned the longer one.
  HSTS_MAX_AGE = 15_768_000

  # nginx's 1m default silently 413s music.ltvb.nl's uploads, which Apache
  # accepted. Generous rather than clever: FPM and Rails both enforce their own
  # limits behind this.
  CLIENT_MAX_BODY_SIZE = "512m".freeze

  # Shared between the nginx `map` that scrubs access logs and the test that
  # proves the scrub works, so the two cannot drift. It anchors on `?auth_token=`
  # or `&auth_token=`, so a parameter merely ending in `auth_token` is left
  # alone. The lookahead skips a value that is ALREADY exactly the marker —
  # without it the greedy second pass just re-redacts the parameter the first
  # pass did, and a duplicated auth_token survives into the log. No backslashes
  # and no brackets, because this string is read twice: once by nginx's config
  # lexer and once by PCRE.
  #
  # NAMED captures, not positional. nginx's map accepts `${name}` but rejects
  # `${1}` outright — `nginx: [emerg] unknown "1" variable`, and the whole
  # config fails to load, so every site on the box is down rather than merely
  # logging unscrubbed. Verified against nginx 1.30.4 with a minimal config:
  # `${pre}` parses, `${1}` does not.
  AUTH_TOKEN_PATTERN     = "^(?<pre>.*[?&]auth_token=)(?!REDACTED(?:&|$))[^&]*(?<post>.*)$".freeze
  AUTH_TOKEN_REPLACEMENT = "${pre}REDACTED${post}".freeze

  # Characters that would end the current directive or open/close a block, plus
  # anything nginx treats as quoting, variable interpolation or a comment, plus
  # all whitespace (every value here is a single nginx token — a space would
  # turn one argument into two) and every control character.
  FORBIDDEN = /[\s;{}#'"\\$`]|[\p{Cntrl}]/

  HOSTNAME_FORMAT    = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/
  ABSOLUTE_PATH      = %r{\A/[A-Za-z0-9._@+/-]*\z}
  URI_PATH           = %r{\A/[A-Za-z0-9._~/-]*\z}
  MAX_VALUE_BYTES    = 255

  class << self
    def render(app, staging: false)
      new(app, staging: staging).render
    end

    # The http{} half: log format and maps must be defined once, above every
    # site. Included by /etc/ltvb/nginx/nginx.conf before any server block.
    def shared_http_config
      erb("nginx-http-shared", auth_token_pattern: AUTH_TOKEN_PATTERN,
                               auth_token_replacement: AUTH_TOKEN_REPLACEMENT)
    end

    # ---- validators -------------------------------------------------------
    #
    # These are the trust boundary. Each one is an allow-list: it says what a
    # value may look like, never what it may not, so a character nobody thought
    # of is rejected by default. `safe!` is the shared deny-list underneath —
    # redundant with the allow-lists on purpose, because it produces the error
    # message that names the offending character.

    def safe!(value, field:)
      string = value.to_s
      raise UnsafeValue, "#{field} is blank" if string.empty?
      raise UnsafeValue, "#{field} is longer than #{MAX_VALUE_BYTES} bytes" if string.bytesize > MAX_VALUE_BYTES
      raise UnsafeValue, "#{field} is not ASCII: #{string.inspect}" unless string.ascii_only?

      bad = string[FORBIDDEN]
      raise UnsafeValue, "#{field} contains #{bad.inspect}, which could inject an nginx directive" if bad

      string
    end

    def safe_fqdn!(value, field: "hostname")
      fqdn = safe!(value, field: field)
      unless fqdn.match?(HOSTNAME_FORMAT) && fqdn.length <= 253
        raise UnsafeValue, "#{field} #{fqdn.inspect} is not a dotted hostname"
      end

      fqdn
    end

    # Filesystem paths land in root/alias/fastcgi_pass, so a `..` segment is as
    # dangerous as a `;` — it escapes the webspace without any punctuation.
    def safe_path!(value, field:)
      path = safe!(value, field: field)
      raise UnsafeValue, "#{field} #{path.inspect} is not an absolute path" unless path.match?(ABSOLUTE_PATH)
      raise UnsafeValue, "#{field} #{path.inspect} contains a .. segment" if path.split("/").include?("..")

      path
    end

    # Request paths (a `location` prefix). Narrower than a filesystem path: no
    # query, no regex metacharacters, nothing nginx would read as a modifier.
    def safe_uri_path!(value, field:)
      path = safe!(value, field: field)
      raise UnsafeValue, "#{field} #{path.inspect} must start with / and be a plain path" unless path.match?(URI_PATH)
      raise UnsafeValue, "#{field} #{path.inspect} contains a .. segment" if path.split("/").include?("..")

      path
    end

    # `allow`/`deny` take an address or CIDR. A hostname would make nginx
    # resolve at load time (and silently allow whatever that name points at
    # later), so only literals are accepted.
    def safe_ip!(value, field: "ip_allowlist")
      entry = safe!(value, field: field)
      address, prefix, extra = entry.split("/", 3)
      raise UnsafeValue, "#{field} entry #{entry.inspect} is not an address or CIDR" if extra || address.to_s.empty?
      raise UnsafeValue, "#{field} entry #{entry.inspect} has a bad prefix length" if prefix && !prefix.match?(/\A\d{1,3}\z/)

      begin
        IPAddr.new(entry)
      rescue ArgumentError, IPAddr::Error
        raise UnsafeValue, "#{field} entry #{entry.inspect} is not an IP address or CIDR block"
      end

      entry
    end

    def safe_port!(value, field:)
      port = begin
        Integer(value.to_s, 10)
      rescue TypeError, ArgumentError
        raise UnsafeValue, "#{field} #{value.inspect} is not a port number"
      end
      raise UnsafeValue, "#{field} #{port} is out of range" unless port.between?(1, 65_535)

      port
    end

    # ---- template location ------------------------------------------------
    #
    # Re-resolved per render rather than memoised: writing a vhost happens a few
    # times per deploy, and an operator who reinstalls a template on the server
    # should not have to restart Passenger to see it — nor should a directory
    # that became writable keep passing a check that ran once at boot.

    def erb(name, **variables)
      # result_with_hash, not a binding: the template gets exactly these
      # variables and no access to this class, and a variable a caller forgot
      # is a NameError rather than a silently empty interpolation.
      ERB.new(File.read(template_path(name)), trim_mode: "-").result_with_hash(variables)
    end

    def template_path(name)
      dir = installed_template_dir
      return trusted_template!(dir.join("#{name}.erb")) if dir

      unless Rails.env.development? || Rails.env.test?
        raise UnsafeValue, "#{TEMPLATE_DIR} is not installed; refusing to render templates from #{Rails.root} " \
                           "(see the install step in deploy/agent/README.md)"
      end

      DEV_TEMPLATE_DIR.join("#{name}.erb")
    end

    # nil when the directory is simply absent, which is what a development
    # machine looks like. Present-but-untrusted is fatal instead: silently
    # falling back to the checkout because an attacker managed to chmod a
    # directory would hand them the thing this constant exists to deny.
    def installed_template_dir
      stat = File.lstat(TEMPLATE_DIR)
      unless stat.directory? && stat.uid.zero? && (stat.mode & 0o022).zero?
        raise UnsafeValue, "#{TEMPLATE_DIR} must be a root-owned directory that nobody else can write"
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
        raise UnsafeValue, "#{path} must be a plain root-owned file that nobody else can write"
      end

      path
    rescue Errno::ENOENT
      raise UnsafeValue, "#{path} is not installed"
    end
  end

  attr_reader :app

  def initialize(app, staging: false)
    @app = app
    @staging = staging
  end

  def render
    self.class.erb("nginx-site", **variables)
  end

  def staging? = @staging

  # The whole parameter set the template branches on, validated. Public because
  # it is the contract between this class and the agent's `render_site`: the
  # test that keeps the two renderers honest compares these hashes as well as
  # the bytes they produce.
  #
  # Every value is resolved and validated before a byte is rendered, so a bad
  # record fails loudly and completely instead of producing a truncated server
  # block. Kind-specific values are still checked for every kind: the cost is
  # nothing and it means an app that changes kind cannot smuggle a value in
  # through the field its old kind ignored.
  def variables
    unless App::SERVED_KINDS.include?(app.app_kind.to_s)
      raise UnsafeValue, "#{app.app_kind.inspect} apps do not get an nginx vhost"
    end

    {
      fqdn: fqdn, kind: app.app_kind.to_s, staging: staging?,
      tls: tls?, redirect_http: redirect_http?, default_server: default_server?,
      http_port: ports[:http], https_port: ports[:https],
      hsts: hsts?, hsts_max_age: HSTS_MAX_AGE, client_max_body: CLIENT_MAX_BODY_SIZE,
      cert_dir: cert_dir, log_dir: log_dir, log_prefix: log_prefix,
      acme_root: ACME_WEBROOT, docroot: document_root, allow: allow_entries,
      app_socket: app_socket, fpm_socket: fpm_socket,
      cable_path: cable_location, cable_upstream: cable_upstream,
      xaccel_location: XACCEL_LOCATION, xaccel_root: xaccel_root
    }
  end

  private

  # ---- validated values ----------------------------------------------------

  def fqdn
    @fqdn ||= self.class.safe_fqdn!(app.fqdn, field: "fqdn")
  end

  def document_root
    @document_root ||= self.class.safe_path!(app.public_path, field: "document root")
  end

  # Derived from the already-validated fqdn rather than stored, so there is no
  # field an operator could point at another app's socket.
  def app_socket  = "#{SOCKET_ROOT}/#{fqdn}/#{SOCKET_NAME}"
  def fpm_socket  = "#{FPM_SOCKET_ROOT}/#{fqdn}/php-fpm.sock"
  def cert_dir    = "#{CERT_ROOT}/#{fqdn}"
  def log_dir     = "#{LOG_ROOT}/#{fqdn}"

  # Live and staging write to the same directory but different files: the point
  # of staging is to compare the two, which is impossible if they interleave.
  def log_prefix = staging? ? "staging-" : ""

  def allow_entries
    @allow_entries ||= app.ip_allowlist_entries.map { |entry| self.class.safe_ip!(entry) }
  end

  # "" rather than nil for the absent case: the template asks `.empty?`, and an
  # optional value that can be two different falsy things is a branch waiting to
  # be got wrong on one side.
  def cable_location
    @cable_location ||= if optional(:cable_path).present?
      self.class.safe_uri_path!(optional(:cable_path), field: "cable_path")
    else
      ""
    end
  end

  # git.ltvb.nl runs ActionCable as a separate standalone Puma on a loopback
  # port, not in the web process — hence a port rather than a bare boolean. An
  # app that cables from its own process leaves it blank and gets its own socket.
  def cable_upstream
    port = optional(:cable_port)
    return "http://unix:#{app_socket}:" if port.blank?

    "http://127.0.0.1:#{self.class.safe_port!(port, field: 'cable_port')}"
  end

  def xaccel_root
    @xaccel_root ||= if optional(:xaccel_path).present?
      self.class.safe_path!(optional(:xaccel_path), field: "xaccel_path")
    else
      ""
    end
  end

  def ports = staging? ? STAGING_PORTS : LIVE_PORTS

  # ---- typed flags ---------------------------------------------------------

  # Vhost fields that become columns on `apps`. Read defensively so this
  # renderer works against a record that predates the column and against a test
  # double that implements only part of the interface. A missing field always
  # means "no customisation" — never "free text".
  def optional(name)
    app.respond_to?(name) ? app.public_send(name) : nil
  end

  # Every hostname on this box has a certificate, so https is the default; the
  # flag exists because the agent has it, and a preview that cannot express a
  # state the writer can express is a preview that lies.
  def tls? = optional(:tls) != false

  # ai., components. and github.lucasvanbriemen.nl plus lucasvanbriemen.nl serve
  # real content on :80 today. Redirecting is the default because forgetting to
  # redirect is the failure that matters; this flag is how the four opt out.
  def redirect_http? = optional(:redirect_http) != false

  # Staging shares the hostname with live, and HSTS is scoped to the host, not
  # the port — a max-age from :9443 would pin the browser for the real site too.
  def hsts? = optional(:hsts).present? && !staging?

  # Unmatched SNI has to land somewhere. Apache made lucasvanbriemen.nl the
  # IPv4 default; declare it on both families, because "whichever server block
  # nginx read first" is not a decision anyone should be making by accident.
  def default_server? = optional(:default_server) ? true : false
end
