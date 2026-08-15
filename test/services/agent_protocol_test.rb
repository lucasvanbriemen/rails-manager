require "test_helper"
require "tmpdir"

# The agent is the root privilege boundary. Its schema, its type predicates and
# its file-replacement logic are therefore written as pure functions with no
# socket and no root, precisely so this file can attack them directly — a
# security test that needs a live daemon is a test that stops being run.
#
# `load` rather than `require`: the daemon has no .rb extension because root
# installs it as an executable, and its `if $PROGRAM_NAME == __FILE__` guard
# keeps loading it here from starting a server.
load Rails.root.join("deploy/agent/ltvb-agentd").to_s

class AgentProtocolTest < ActiveSupport::TestCase
  WEBSPACES = LtvbAgent::Webspaces.new(LtvbAgent::Webspaces::DEFAULT)

  # Webspaces::DEFAULT is the conservative table the daemon boots with when
  # webspaces.json is missing; the box's own file has all six manageable, which
  # is what the rendering tests need in order to cover an apex site in a webspace
  # the fallback marks read-only.
  RENDERABLE = LtvbAgent::Webspaces.new(
    LtvbAgent::Webspaces::DEFAULT.transform_values { |attrs| attrs.merge("manageable" => true) }
  )

  # A manageable host, a read-only host, and the apex of each — the four shapes
  # every verb has to get right.
  MANAGED   = "git.ltvb.nl".freeze
  READ_ONLY = "admin.rijschool-mos.nl".freeze

  def validate(verb, params)
    LtvbAgent::Schema.validate!(verb, params, webspaces: WEBSPACES)
  end

  # Reports WHICH input got through — with a table this size, "nothing was
  # raised" on its own is not a usable failure message.
  def refute_accepted(verb, params, message = nil)
    validate(verb, params)
    flunk(message || "#{verb} accepted #{params.inspect}")
  rescue LtvbAgent::Invalid
    assert true
  end

  # ---- rendering helpers ----------------------------------------------------
  #
  # These drive the agent's real path — schema validation and all — from an App
  # record, so the comparison against NginxConfig is between two things that both
  # started from the same row rather than between two hand-written fixtures.

  def handlers
    @handlers ||= LtvbAgent::Handlers.new(webspaces: RENDERABLE, config: LtvbAgent::Config::DEFAULT)
  end

  # No validations are run: the renderer must be able to be handed rows the model
  # would have rejected, because a row can come from a console or an import.
  # `tls` is not a column yet, so it arrives the way the other vhost flags did
  # before their migrations — as a reader the renderer finds by responding to it.
  def render_app(**overrides)
    columns  = App.column_names.map(&:to_sym)
    defaults = { name: "test app", app_kind: "rails", subdomain: "git", domain: "ltvb.nl",
                 git_repo_url: "git@github.com:ltvb/test.git", doc_root_suffix: "public" }

    app = App.new(defaults.merge(overrides).slice(*columns))
    overrides.except(*columns).each { |name, value| app.define_singleton_method(name) { value } }
    app
  end

  # The render spec the manager would send for this app. Compacted because an
  # optional parameter is expressed by being absent — sending an explicit null is
  # a schema error, deliberately, so "unset" cannot be spelled two ways.
  def agent_spec(app, staging)
    {
      "fqdn" => app.fqdn, "kind" => app.app_kind, "suffix" => app.doc_root_suffix.to_s,
      "staging" => staging, "tls" => app.respond_to?(:tls) ? app.tls : true,
      "hsts" => app.hsts, "redirect_http" => app.redirect_http,
      "default_server" => app.default_server, "allow" => app.ip_allowlist_entries,
      "cable_path" => app.cable_path.presence, "cable_port" => app.cable_port,
      "xaccel" => app.xaccel_path.presence
    }.compact
  end

  def agent_site_config(app, staging: false)
    params = LtvbAgent::Schema.validate!("nginx.site.write", agent_spec(app, staging), webspaces: RENDERABLE)

    handlers.send(:render_site, RENDERABLE.resolve(app.fqdn), params)
  end

  # ---- verbs and keys -------------------------------------------------------

  test "an unknown verb is refused by name, not silently treated as a no-op" do
    error = assert_raises(LtvbAgent::Invalid) { validate("nginx.write", {}) }
    assert_equal "unknown_verb", error.code
  end

  test "a verb that is not a string is refused before any lookup" do
    [ nil, 1, [ "ping" ], { "verb" => "ping" }, :ping ].each do |verb|
      error = assert_raises(LtvbAgent::Invalid) { validate(verb, {}) }
      assert_equal "unknown_verb", error.code, "accepted verb #{verb.inspect}"
    end
  end

  test "unknown parameters are a hard error rather than being ignored" do
    error = assert_raises(LtvbAgent::Invalid) do
      validate("http.check", { "fqdn" => MANAGED, "follow_redirects" => true })
    end
    assert_match(/unknown parameter/, error.message)
    assert_match(/follow_redirects/, error.message)
  end

  test "a smuggled extra key is refused even when every declared key is valid" do
    # The failure this prevents: a caller adds a parameter, the agent ignores
    # it, and both sides believe the request meant different things.
    refute_accepted("plesk.subdomain.create",
                    { "subdomain" => "new", "domain" => "ltvb.nl", "www_root" => "/etc" })
  end

  test "missing required parameters are named" do
    error = assert_raises(LtvbAgent::Invalid) { validate("plesk.ruby.enable", { "fqdn" => MANAGED }) }
    assert_match(/missing required parameter version/, error.message)
  end

  test "optional parameters get their declared defaults" do
    assert_equal({ fqdn: MANAGED, path: "/", port: 443, tls: true }, validate("http.check", { "fqdn" => MANAGED }))
  end

  test "params must be an object" do
    [ nil, "fqdn=git.ltvb.nl", [ "fqdn", MANAGED ], 7 ].each do |params|
      refute_accepted("http.check", params, "accepted params #{params.inspect}")
    end
  end

  test "a payload carrying both a string and a symbol form of one key is refused" do
    # Which of the two the agent acted on would otherwise depend on hash order.
    refute_accepted("http.check", { "fqdn" => MANAGED, :fqdn => "login.ltvb.nl" })
  end

  test "parameter names that are not strings or symbols are refused" do
    refute_accepted("http.check", { 1 => MANAGED })
  end

  # ---- injection ------------------------------------------------------------

  # Every one of these is accepted by a /^[a-z0-9.-]+$/ style check, which is
  # what the bash wrapper used. \A..\z plus the control-character gate is what
  # makes them fail here.
  NEWLINE_INJECTIONS = [
    "git.ltvb.nl\nrm -rf /",
    "git.ltvb.nl\n",
    "\ngit.ltvb.nl",
    "git.ltvb.nl\r\nX-Injected: 1",
    "git.ltvb.nl\rrm -rf /"
  ].freeze

  SHELL_INJECTIONS = [
    "git.ltvb.nl; rm -rf /",
    "git.ltvb.nl && reboot",
    "git.ltvb.nl | tee /etc/passwd",
    "$(reboot)",
    "`reboot`",
    "git.ltvb.nl > /etc/shadow",
    "--version",
    "-rf",
    "git.ltvb.nl ",
    " git.ltvb.nl"
  ].freeze

  NULL_AND_CONTROL = [
    "git.ltvb.nl\u0000",
    "git\u0000.ltvb.nl",
    "\u0000",
    "git.ltvb.nl\u001B[2J",
    "git.ltvb.nl\u0007",
    "git.ltvb.nl\u007F",
    "git.ltvb.nl\u0085"
  ].freeze

  # Every one of these renders as "git.ltvb.nl" or close enough to fool a human
  # reading an audit log, and none of them is the ASCII hostname.
  UNICODE_TRICKS = [
    "gіt.ltvb.nl",       # U+0456 CYRILLIC SMALL LETTER BYELORUSSIAN-UKRAINIAN I
    "git\uFF0Eltvb.nl",  # U+FF0E FULLWIDTH FULL STOP
    "git.ltvb.nl\u202E", # right-to-left override
    "git.ltvb.nl\u200B", # zero-width space
    "ｇｉｔ.ltvb.nl",     # fullwidth letters
    "GIT.LTVB.NL",       # not lowercased for us: the agent transforms nothing
    "git.ltvb.nl."       # trailing root dot
  ].freeze

  test "hostname parameters reject newline injection" do
    NEWLINE_INJECTIONS.each do |value|
      refute_accepted("http.check", { "fqdn" => value }, "accepted #{value.inspect}")
    end
  end

  test "hostname parameters reject shell metacharacters and option-looking values" do
    SHELL_INJECTIONS.each do |value|
      refute_accepted("http.check", { "fqdn" => value }, "accepted #{value.inspect}")
    end
  end

  test "hostname parameters reject null bytes and other control characters" do
    NULL_AND_CONTROL.each do |value|
      refute_accepted("http.check", { "fqdn" => value }, "accepted #{value.inspect}")
    end
  end

  test "hostname parameters reject unicode look-alikes" do
    UNICODE_TRICKS.each do |value|
      refute_accepted("http.check", { "fqdn" => value }, "accepted #{value.inspect}")
    end
  end

  test "strings that are not valid UTF-8 are refused" do
    error = assert_raises(LtvbAgent::Invalid) do
      validate("http.check", { "fqdn" => (+"git.ltvb.nl\xED\xA0\x80").force_encoding(Encoding::UTF_8) })
    end
    assert_match(/valid UTF-8/, error.message)
  end

  test "the same attacks are refused on every string type, not just hostnames" do
    (NEWLINE_INJECTIONS + SHELL_INJECTIONS + NULL_AND_CONTROL).each do |value|
      refute_accepted("plesk.subdomain.create", { "subdomain" => value, "domain" => "ltvb.nl" },
                      "label accepted #{value.inspect}")
      refute_accepted("plesk.ruby.enable", { "fqdn" => MANAGED, "version" => value },
                      "version accepted #{value.inspect}")
      refute_accepted("plesk.subdomain.docroot",
                      { "subdomain" => "git", "domain" => "ltvb.nl", "suffix" => value },
                      "suffix accepted #{value.inspect}")
      refute_accepted("nginx.site.write", { "fqdn" => MANAGED, "kind" => value },
                      "enum accepted #{value.inspect}")
      refute_accepted("systemd.status", { "unit" => value }, "unit accepted #{value.inspect}")
      refute_accepted("systemd.unit.install", { "fqdn" => MANAGED, "worker" => value },
                      "worker accepted #{value.inspect}")
      refute_accepted("systemd.unit.install", { "fqdn" => MANAGED, "memory_max" => value },
                      "memory_max accepted #{value.inspect}")
      refute_accepted("nginx.site.write", { "fqdn" => MANAGED, "kind" => "static", "allow" => [ value ] },
                      "allow entry accepted #{value.inspect}")
    end
  end

  # argv elements, env values and a Description= are legitimately free text: a
  # deploy command really does take "--version", and an env value really can
  # contain a semicolon. There is no shell anywhere behind them, so the only
  # characters that still mean something are the ones that end a line — which is
  # exactly what systemd's line-by-line parser would read as a new directive.
  test "free-text unit values reject line breaks and control characters but not punctuation" do
    (NEWLINE_INJECTIONS + NULL_AND_CONTROL).each do |value|
      refute_accepted("systemd.unit.install",
                      { "fqdn" => MANAGED, "worker" => "jobs", "argv" => [ "/bin/true", value ] },
                      "argv element accepted #{value.inspect}")
      refute_accepted("systemd.unit.install", { "fqdn" => MANAGED, "env" => { "K" => value } },
                      "env value accepted #{value.inspect}")
      refute_accepted("systemd.unit.install", { "fqdn" => MANAGED, "description" => value },
                      "description accepted #{value.inspect}")
    end

    clean = validate("systemd.unit.install",
                     { "fqdn" => MANAGED, "worker" => "jobs", "description" => "git.ltvb.nl; jobs",
                       "argv" => [ "/bin/true", "--version" ], "env" => { "K" => "a;b$c" } })
    assert_equal [ "/bin/true", "--version" ], clean[:argv]
    assert_equal({ "K" => "a;b$c" }, clean[:env])
  end

  test "a version is digits and dots only" do
    assert_equal "3.3.8", validate("plesk.ruby.enable", { "fqdn" => MANAGED, "version" => "3.3.8" })[:version]
    [ "3.3.8; reboot", "3.3.8 --force", "latest", "3..8", ".3.3", "3.3.", "3.3.8.1.2", "99999" ].each do |value|
      refute_accepted("plesk.ruby.enable", { "fqdn" => MANAGED, "version" => value }, "accepted #{value.inspect}")
    end
  end

  # ---- paths ----------------------------------------------------------------

  test "the document-root suffix cannot spell a traversal because it has no dots" do
    [ "..", "../..", "public/../../../etc", ".", "./public", "public/.ssh", "/etc/nginx",
      "public//..", "pub\\lic", "public;", "~root" ].each do |value|
      refute_accepted("plesk.subdomain.docroot",
                      { "subdomain" => "git", "domain" => "ltvb.nl", "suffix" => value },
                      "accepted suffix #{value.inspect}")
    end
  end

  test "the document-root suffix accepts the two shapes this server actually uses" do
    %w[public httpdocs/public].each do |value|
      assert_equal value, validate("plesk.subdomain.docroot",
                                   { "subdomain" => "git", "domain" => "ltvb.nl", "suffix" => value })[:suffix]
    end
    assert_equal "", validate("plesk.subdomain.docroot", { "subdomain" => "git", "domain" => "ltvb.nl" })[:suffix]
  end

  test "a site root is derived from the agent's own table, never from the request" do
    site = WEBSPACES.resolve(MANAGED)
    assert_equal "/var/www/vhosts/ltvb.nl/git.ltvb.nl", site.root
    assert_equal "ltvb.nl", site.domain
    assert_equal "ltvb", site.owner
  end

  test "the apex of a webspace resolves to httpdocs, not to a directory named after itself" do
    site = WEBSPACES.resolve("ltvb.nl")
    assert site.apex
    assert_equal "/var/www/vhosts/ltvb.nl/httpdocs", site.root
  end

  test "hostnames outside the webspace table resolve to no path at all" do
    # There is nothing to traverse INTO because nothing is derived: an unknown
    # name simply has no directory.
    [ "example.com", "ltvb.nl.attacker.example", "notltvb.nl", "xltvb.nl",
      "git.ltvb.nl.evil.com", "a.b.ltvb.nl", "ltvb.nl/../..", "../ltvb.nl" ].each do |fqdn|
      assert_nil WEBSPACES.resolve(fqdn), "resolved #{fqdn.inspect}"
    end
  end

  test "a suffix-confusion hostname is not treated as belonging to the webspace it ends with" do
    # "evilltvb.nl".end_with?("ltvb.nl") is true; the table match requires the
    # dot, so this must not inherit ltvb.nl's directory or its owner.
    assert_nil WEBSPACES.resolve("evilltvb.nl")
    refute_accepted("http.check", { "fqdn" => "evilltvb.nl" })
  end

  test "an unknown host is rejected with a code the manager can act on" do
    error = assert_raises(LtvbAgent::Invalid) { validate("http.check", { "fqdn" => "example.com" }) }
    assert_equal "unknown_domain", error.code
  end

  test "validation does not mutate the caller's parameters" do
    params = { "fqdn" => MANAGED }
    validate("http.check", params)
    assert_equal({ "fqdn" => MANAGED }, params, "defaults must be applied to a copy, not written back")
  end

  # ---- the webspace table itself -------------------------------------------

  test "a webspace table with a key that is not a hostname refuses to load" do
    # This table is the only source of paths, so a malformed one is a boot
    # failure rather than something to discover on the first mutating call.
    [ "../../etc", "ltvb.nl/../..", "LTVB.NL", "", "ltvb.nl\nevil.com" ].each do |domain|
      assert_raises(LtvbAgent::Failure, "loaded table keyed #{domain.inspect}") do
        LtvbAgent::Webspaces.new(domain => { "owner" => "root", "manageable" => true })
      end
    end
  end

  test "manageable defaults to false for anything the table does not explicitly allow" do
    table = LtvbAgent::Webspaces.new("example.com" => { "owner" => "nobody" })
    refute table.manageable?("example.com")
    refute table.manageable?("not-in-the-table.com")
  end

  test "the shipped table matches the six webspaces on this server" do
    assert_equal %w[djtim.eu ltvb.nl lucasvanbriemen.nl mos-safeguards.com
                    rijschool-mos.nl voordezorgmanagement.nl].sort, WEBSPACES.domains.sort
    assert_equal %w[ltvb.nl lucasvanbriemen.nl].sort,
                 WEBSPACES.domains.select { |d| WEBSPACES.manageable?(d) }.sort
  end

  # ---- config ---------------------------------------------------------------

  test "a missing config file falls back to the compiled-in default so a fresh install boots" do
    in_tmpdir do |dir|
      assert_nil LtvbAgent::Config.read_json(File.join(dir, "absent.json"))
    end
  end

  test "a config file anyone but root can write is fatal rather than ignored" do
    # Silently falling back to the default would let an attacker who gained a
    # write to /etc/ltvb choose the agent's policy by breaking its permissions.
    in_tmpdir do |dir|
      path = File.join(dir, "agent.json")
      File.write(path, %({"allowed_users":["root"]}))
      File.chmod(0o666, path)
      assert_raises(LtvbAgent::Failure) { LtvbAgent::Config.read_json(path, owner: Process.uid) }
    end
  end

  test "a config file that is not JSON is fatal" do
    in_tmpdir do |dir|
      path = File.join(dir, "agent.json")
      File.write(path, "allowed_users = ltvb")
      File.chmod(0o600, path)
      error = assert_raises(LtvbAgent::Failure) { LtvbAgent::Config.read_json(path, owner: Process.uid) }
      assert_match(/invalid JSON/, error.message)
    end
  end

  test "a valid config file is read" do
    in_tmpdir do |dir|
      path = File.join(dir, "agent.json")
      File.write(path, %({"allowed_users":["ltvb-manager"]}))
      File.chmod(0o600, path)
      assert_equal({ "allowed_users" => [ "ltvb-manager" ] }, LtvbAgent::Config.read_json(path, owner: Process.uid))
    end
  end

  # ---- authorisation --------------------------------------------------------

  test "mutating verbs are refused on webspaces root marked read-only" do
    error = assert_raises(LtvbAgent::Invalid) do
      validate("plesk.subdomain.create", { "subdomain" => "new", "domain" => "rijschool-mos.nl" })
    end
    assert_equal "not_manageable", error.code
  end

  test "a mutating verb addressed by fqdn checks the parent webspace, not the hostname" do
    error = assert_raises(LtvbAgent::Invalid) { validate("plesk.reconfigure", { "fqdn" => READ_ONLY }) }
    assert_equal "not_manageable", error.code
  end

  test "read-only verbs work on every webspace" do
    assert_equal READ_ONLY, validate("http.check", { "fqdn" => READ_ONLY })[:fqdn]
  end

  # ---- scalar types ---------------------------------------------------------

  test "a port must be an integer in range, not a string or a float or a boolean" do
    [ "443", 443.0, true, nil, 0, -1, 65_536, 1e5 ].each do |value|
      refute_accepted("http.check", { "fqdn" => MANAGED, "port" => value }, "accepted port #{value.inspect}")
    end
    assert_equal 9443, validate("http.check", { "fqdn" => MANAGED, "port" => 9443 })[:port]
  end

  test "a boolean must be a real boolean" do
    [ "true", "false", 1, 0, nil, "yes" ].each do |value|
      refute_accepted("http.check", { "fqdn" => MANAGED, "tls" => value }, "accepted tls #{value.inspect}")
    end
    assert_equal false, validate("http.check", { "fqdn" => MANAGED, "tls" => false })[:tls]
  end

  test "a request path must be absolute and free of whitespace" do
    [ "up", "", "http://elsewhere/", "/up /etc", "/up\nHost: x", "/up\u0000", "//\\", " /up" ].each do |value|
      refute_accepted("http.check", { "fqdn" => MANAGED, "path" => value }, "accepted path #{value.inspect}")
    end
    assert_equal "/up?x=1", validate("http.check", { "fqdn" => MANAGED, "path" => "/up?x=1" })[:path]
  end

  test "oversized scalars are refused before anything looks at them" do
    refute_accepted("http.check", { "fqdn" => "a" * 5000 })
    assert_raises(LtvbAgent::Invalid) { LtvbAgent::Types.text!(:env_text, "x" * (64 * 1024 + 1)) }
  end

  test "text parameters allow newlines and tabs but no other control characters" do
    assert_equal "A=1\nB=2\n", LtvbAgent::Types.text!(:env_text, "A=1\nB=2\n")
    assert_raises(LtvbAgent::Invalid) { LtvbAgent::Types.text!(:env_text, "A=1\u0000") }
    assert_raises(LtvbAgent::Invalid) { LtvbAgent::Types.text!(:env_text, "A=1\u001B[2J") }
  end

  # ---- wire framing ---------------------------------------------------------

  test "a request line longer than the cap is refused instead of buffered" do
    io = StringIO.new(("x" * 100) + "\n")
    error = assert_raises(LtvbAgent::Invalid) { LtvbAgent::Wire.read_line(io, limit: 32) }
    assert_equal "oversize", error.code
  end

  test "a line exactly at the cap is still accepted" do
    io = StringIO.new(("x" * 31) + "\n")
    assert_equal 32, LtvbAgent::Wire.read_line(io, limit: 32).bytesize
  end

  test "a clean end of stream reads as nil, not as an error" do
    assert_nil LtvbAgent::Wire.read_line(StringIO.new(""))
  end

  test "malformed and hostile JSON is refused" do
    [
      "not json\n",
      "[1,2,3]\n",
      '"just a string"' + "\n",
      "{}\n",
      %({"verb": 1}\n),
      %({"verb": "ping", "params": []}\n),
      %({"verb": "ping", "extra": 1}\n),
      # A lone surrogate never becomes a Ruby string here at all.
      %({"verb": "ping", "params": {"fqdn": "\\ud800"}}\n),
      # Deep nesting is a parser denial-of-service, not a request.
      %({"verb":"ping","params":#{"[" * 20}#{"]" * 20}}\n)
    ].each do |line|
      assert_raises(LtvbAgent::Invalid, "accepted #{line.inspect}") { LtvbAgent::Wire.parse(line) }
    end
  end

  test "a well-formed request parses into id, verb and params" do
    id, verb, params = LtvbAgent::Wire.parse(%({"id":"abc","verb":"http.check","params":{"fqdn":"#{MANAGED}"}}\n))
    assert_equal "abc", id
    assert_equal "http.check", verb
    assert_equal({ "fqdn" => MANAGED }, params)
  end

  test "escaped control characters survive JSON but not the schema" do
    # This is the whole reason the type gate exists: JSON.parse turns "\u0000"
    # and "\r\n" into real control characters, so the parser cannot be the last
    # line of defence.
    _id, verb, params = LtvbAgent::Wire.parse(%({"verb":"http.check","params":{"fqdn":"git\\u0000.ltvb.nl"}}\n))
    assert_equal "git\u0000.ltvb.nl", params["fqdn"]
    refute_accepted(verb, params)
  end

  # ---- audit ----------------------------------------------------------------

  SECRET_SPEC = { env_text: { type: :text, secret: true }, fqdn: { type: :fqdn } }.freeze

  test "secret parameters are audited by name and digest, never by value" do
    secret = "RAILS_MASTER_KEY=0123456789abcdef\n"
    line = LtvbAgent::Audit.redact({ env_text: secret, fqdn: MANAGED }, SECRET_SPEC)

    assert_equal({ "param" => "env_text", "sha256" => Digest::SHA256.hexdigest(secret), "bytes" => secret.bytesize },
                 line["env_text"])
    assert_equal MANAGED, line["fqdn"]
    refute_includes JSON.generate(line), "0123456789abcdef"
  end

  test "redaction keys off the schema, so a parameter renamed without the flag is not silently exposed" do
    line = LtvbAgent::Audit.redact({ env_text: "s3cret" }, { env_text: { type: :text } })
    assert_equal "s3cret", line["env_text"]
  end

  test "the digest identifies which secret was installed without storing it" do
    a = LtvbAgent::Audit.redact({ env_text: "one" }, SECRET_SPEC)["env_text"]
    b = LtvbAgent::Audit.redact({ env_text: "one" }, SECRET_SPEC)["env_text"]
    c = LtvbAgent::Audit.redact({ env_text: "two" }, SECRET_SPEC)["env_text"]
    assert_equal a["sha256"], b["sha256"]
    refute_equal a["sha256"], c["sha256"]
  end

  # ---- two-phase writes -----------------------------------------------------

  def in_tmpdir
    Dir.mktmpdir("ltvb-agent-test") { |dir| yield dir }
  end

  def replace(path, content, validate: ->(_) { true }, reload: -> { true })
    LtvbAgent::AtomicWrite.replace(path, content, validate: validate, reload: reload, owner: Process.uid)
  end

  test "a good write is staged, validated, renamed and reloaded once" do
    in_tmpdir do |dir|
      path = File.join(dir, "site.conf")
      File.write(path, "old\n")
      reloads = 0

      seen = nil
      assert_equal :written, replace(path, "new\n", validate: ->(staged) { seen = File.read(staged); true },
                                                    reload: -> { reloads += 1; true })

      assert_equal "new\n", seen, "the validator must see the new content, not the live file"
      assert_equal "new\n", File.read(path)
      assert_equal 1, reloads
      refute File.exist?("#{path}.new")
      refute File.exist?("#{path}.bak"),
             "the backup exists for the rollback path; leaving it behind leaves a second copy of a secret"
    end
  end

  test "the backup is created with the mode of the file it protects, not the umask" do
    # The first file this mechanism guards is ltvb-app@login.ltvb.nl.service,
    # whose Environment= line is the only copy of that app's RAILS_MASTER_KEY on
    # a box where eight internet-facing apps share one uid. File.binwrite would
    # make the .bak 0644 and hand them the key.
    in_tmpdir do |dir|
      path = File.join(dir, "unit.service")
      File.write(path, "old\n")
      File.chmod(0o600, path)

      modes = []
      LtvbAgent::AtomicWrite.replace(path, "new\n", mode: 0o600, owner: Process.uid,
                                                    validate: ->(_) { true },
                                                    reload: -> { modes << (File.stat("#{path}.bak").mode & 0o777); true })

      assert_equal [ 0o600 ], modes
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  test "the backup survives a rollback, because that is the only time anyone wants it" do
    in_tmpdir do |dir|
      path = File.join(dir, "unit.service")
      File.write(path, "old\n")

      assert_raises(LtvbAgent::Failure) { replace(path, "new\n", reload: -> { false }) }
      assert_equal "old\n", File.read("#{path}.bak")
    end
  end

  test "a backup path occupied by a symlink is refused rather than written through" do
    in_tmpdir do |dir|
      path   = File.join(dir, "site.conf")
      canary = File.join(dir, "canary")
      File.write(path, "old\n")
      File.write(canary, "untouched\n")
      File.symlink(canary, "#{path}.bak")

      assert_raises(LtvbAgent::Failure) { replace(path, "new\n") }
      assert_equal "untouched\n", File.read(canary)
      assert_equal "old\n", File.read(path)
    end
  end

  # ---- removal --------------------------------------------------------------

  test "removing a file keeps a copy, unlinks, and reloads once" do
    in_tmpdir do |dir|
      path = File.join(dir, "site.conf")
      File.write(path, "old\n")
      reloads = 0

      assert_equal :removed, LtvbAgent::AtomicWrite.remove(path, owner: Process.uid,
                                                                 reload: -> { reloads += 1; true })
      refute File.exist?(path)
      refute File.exist?("#{path}.bak")
      assert_equal 1, reloads
    end
  end

  test "removing a file the reload will not accept puts it back with its mode intact" do
    in_tmpdir do |dir|
      path = File.join(dir, "unit.service")
      File.write(path, "old\n")
      File.chmod(0o600, path)
      seen = []

      assert_raises(LtvbAgent::Invalid) do
        LtvbAgent::AtomicWrite.remove(path, mode: 0o600, owner: Process.uid,
                                            reload: -> { seen << File.exist?(path); seen.size > 1 })
      end

      assert_equal [ false, true ], seen, "the second reload must run against the restored file"
      assert_equal "old\n", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777, "a restored unit must not come back world-readable"
    end
  end

  test "removing a file that is already gone is not an error" do
    in_tmpdir do |dir|
      reloads = 0
      assert_equal :absent, LtvbAgent::AtomicWrite.remove(File.join(dir, "absent.conf"), owner: Process.uid,
                                                                                         reload: -> { reloads += 1; true })
      assert_equal 0, reloads, "nothing changed, so nothing needs reloading"
    end
  end

  test "a validator rejection never touches the live file" do
    in_tmpdir do |dir|
      path = File.join(dir, "site.conf")
      File.write(path, "old\n")
      reloads = 0

      error = assert_raises(LtvbAgent::Invalid) do
        replace(path, "broken\n", validate: ->(_) { false }, reload: -> { reloads += 1; true })
      end

      assert_equal "validation", error.code
      assert_equal "old\n", File.read(path)
      assert_equal 0, reloads, "nothing may be reloaded for a file that never went live"
      refute File.exist?("#{path}.new")
    end
  end

  test "a reload that refuses the new file restores the previous one and reloads again" do
    in_tmpdir do |dir|
      path = File.join(dir, "site.conf")
      File.write(path, "old\n")
      seen = []

      assert_raises(LtvbAgent::Invalid) do
        replace(path, "new\n", reload: -> { seen << File.read(path); seen.size > 1 })
      end

      assert_equal [ "new\n", "old\n" ], seen, "the second reload must run against the restored file"
      assert_equal "old\n", File.read(path)
    end
  end

  test "a file that did not exist before is removed again when the reload refuses it" do
    in_tmpdir do |dir|
      path = File.join(dir, "new-site.conf")
      assert_raises(LtvbAgent::Invalid) { replace(path, "new\n", reload: -> { File.exist?(path) ? false : true }) }
      refute File.exist?(path)
    end
  end

  test "a rollback that still will not reload is escalated rather than reported as handled" do
    in_tmpdir do |dir|
      path = File.join(dir, "site.conf")
      File.write(path, "old\n")

      error = assert_raises(LtvbAgent::Failure) { replace(path, "new\n", reload: -> { false }) }
      assert_equal "broken", error.code
      assert_match(/manual repair/, error.message)
      assert_equal "old\n", File.read(path), "the previous file is still put back before giving up"
    end
  end

  test "a symlink planted at the staging path is refused, not followed" do
    in_tmpdir do |dir|
      path   = File.join(dir, "site.conf")
      canary = File.join(dir, "canary")
      File.write(path, "old\n")
      File.write(canary, "untouched\n")
      File.symlink(canary, "#{path}.new")

      assert_raises(LtvbAgent::Failure) { replace(path, "pwned\n") }
      assert_equal "untouched\n", File.read(canary)
      assert_equal "old\n", File.read(path)
    end
  end

  test "the staged open refuses to follow a symlink that appears after the check" do
    in_tmpdir do |dir|
      canary = File.join(dir, "canary")
      File.write(canary, "untouched\n")
      staged = File.join(dir, "site.conf.new")
      File.symlink(canary, staged)

      # O_EXCL|O_NOFOLLOW is what closes the window between clear_staged! and
      # the open; this calls the open directly to prove it does not depend on
      # the earlier check having run.
      assert_raises(Errno::EEXIST) { LtvbAgent::AtomicWrite.write_staged(staged, "pwned\n", 0o644) }
      assert_equal "untouched\n", File.read(canary)
    end
  end

  test "a leftover staging file from a crashed run is cleared, but only if it is a plain owned file" do
    in_tmpdir do |dir|
      path = File.join(dir, "site.conf")
      File.write(path, "old\n")
      File.write("#{path}.new", "leftover\n")

      assert_equal :written, replace(path, "new\n")
      assert_equal "new\n", File.read(path)
    end
  end

  test "a directory at the staging path is refused rather than removed" do
    in_tmpdir do |dir|
      path = File.join(dir, "site.conf")
      File.write(path, "old\n")
      Dir.mkdir("#{path}.new")

      assert_raises(LtvbAgent::Failure) { replace(path, "new\n") }
      assert File.directory?("#{path}.new")
    end
  end

  test "the staged file is created with the mode it will keep" do
    in_tmpdir do |dir|
      path = File.join(dir, "pool.conf")
      LtvbAgent::AtomicWrite.replace(path, "x\n", validate: ->(_) { true }, reload: -> { true },
                                                  mode: 0o640, owner: Process.uid)
      assert_equal 0o640, File.stat(path).mode & 0o777
    end
  end

  # ---- trusted files and templates -----------------------------------------

  test "a file the agent reads as instructions must be a plain file owned by the expected uid" do
    in_tmpdir do |dir|
      good = File.join(dir, "agent.json")
      File.write(good, "{}")
      File.chmod(0o644, good)
      assert_equal good, LtvbAgent::Trusted.file!(good, owner: Process.uid)

      assert_raises(LtvbAgent::Failure) { LtvbAgent::Trusted.file!(good, owner: Process.uid + 1) }

      File.chmod(0o666, good)
      assert_raises(LtvbAgent::Failure) { LtvbAgent::Trusted.file!(good, owner: Process.uid) }

      link = File.join(dir, "linked.json")
      File.symlink(good, link)
      assert_raises(LtvbAgent::Failure) { LtvbAgent::Trusted.file!(link, owner: Process.uid) }

      assert_raises(LtvbAgent::Failure) { LtvbAgent::Trusted.file!(dir, owner: Process.uid) }
    end
  end

  test "template names cannot escape the template directory" do
    [ "..", ".", "../../etc/nginx/nginx", "nginx/../../../etc/passwd", "a/b", "/etc/passwd",
      "", ".hidden", "a..b", "nginx site", "nginx;", "NGINX", "nginx-", "-nginx", "nginx." ].each do |name|
      assert_raises(LtvbAgent::Invalid, "accepted template name #{name.inspect}") { LtvbAgent::Templates.path(name) }
    end
  end

  test "a template resolves only to a real file inside its own directory" do
    in_tmpdir do |dir|
      File.write(File.join(dir, "nginx-site.erb"), "server_name <%= fqdn %>;\n")
      assert_equal File.join(dir, "nginx-site.erb"),
                   LtvbAgent::Templates.path("nginx-site", dir: dir, owner: Process.uid)

      error = assert_raises(LtvbAgent::Invalid) { LtvbAgent::Templates.path("missing", dir: dir, owner: Process.uid) }
      assert_match(/not installed/, error.message)
    end
  end

  test "a symlinked template is refused even when its name is valid" do
    in_tmpdir do |dir|
      outside = File.join(dir, "attacker.erb")
      File.write(outside, "<%= `id` %>")
      File.symlink(outside, File.join(dir, "nginx-site.erb"))

      assert_raises(LtvbAgent::Failure) { LtvbAgent::Templates.path("nginx-site", dir: dir, owner: Process.uid) }
    end
  end

  test "rendering passes only the variables it was given" do
    in_tmpdir do |dir|
      File.write(File.join(dir, "site.erb"), "server_name <%= fqdn %>;\n")
      assert_equal "server_name git.ltvb.nl;\n",
                   LtvbAgent::Templates.render("site", { fqdn: MANAGED }, dir: dir, owner: Process.uid)

      File.write(File.join(dir, "leaky.erb"), "<%= defined?(WEBSPACES).inspect %>")
      assert_equal "nil", LtvbAgent::Templates.render("leaky", {}, dir: dir, owner: Process.uid)
    end
  end

  test "a template with no installed file falls back to the one compiled into the daemon" do
    in_tmpdir do |dir|
      assert_includes LtvbAgent::Templates.source("nginx-site", dir: dir, owner: Process.uid), "server {"
      error = assert_raises(LtvbAgent::Invalid) do
        LtvbAgent::Templates.source("no-such-template", dir: dir, owner: Process.uid)
      end
      assert_match(/neither installed nor built in/, error.message)
    end
  end

  test "an installed template overrides the built-in, but only if root owns it" do
    in_tmpdir do |dir|
      path = File.join(dir, "nginx-site.erb")
      File.write(path, "overridden\n")
      File.chmod(0o644, path)
      assert_equal "overridden\n", LtvbAgent::Templates.source("nginx-site", dir: dir, owner: Process.uid)

      # Group-writable is fatal, NOT a quiet fall back to the built-in: an
      # attacker who can chmod a template must not get to choose which of the
      # two the agent renders.
      File.chmod(0o664, path)
      assert_raises(LtvbAgent::Failure) { LtvbAgent::Templates.source("nginx-site", dir: dir, owner: Process.uid) }
    end
  end

  test "every template a handler names is either installed or built in" do
    %w[nginx-site systemd-app systemd-worker fpm-pool].each do |name|
      assert LtvbAgent::Templates::DEFAULTS.key?(name), "no built-in template #{name}"
    end
  end

  # ---- one nginx template, two renderers ------------------------------------
  #
  # There used to be two: this daemon's built-in ERB, which writes the served
  # config, and a second set under deploy/templates/nginx that only the manager
  # read. They drifted. The index-precedence fix landed on the manager's copy and
  # changed nothing that was served, and on the box itself admin. and
  # login.rijschool-mos.nl kept `index index.php index.html` while student. — the
  # one site that happened to be re-rendered afterwards — carried the fix.
  #
  # The two tests below are what make that unrepeatable: one holds the daemon's
  # built-in fallback to the authored file, the other holds the manager's preview
  # to the daemon's output byte for byte.

  test "the built-in nginx template is the authored file, not a second copy of it" do
    authored = Rails.root.join("deploy/templates/nginx/nginx-site.erb").read

    assert_equal authored, LtvbAgent::Templates::DEFAULTS["nginx-site"],
                 "the daemon's built-in nginx-site is stale — run: ruby deploy/agent/embed-nginx-template"
  end

  # Every shape the two renderers can disagree about: each kind, each port set,
  # the http-serving exception, the default vhost, HSTS, an allowlist, both cable
  # forms, X-Accel, and tls off.
  RENDER_MATRIX = [
    { app: { app_kind: "rails",   subdomain: "git" } },
    { app: { app_kind: "rails",   subdomain: "git" }, staging: true },
    { app: { app_kind: "laravel", subdomain: "senne" } },
    { app: { app_kind: "php",     subdomain: "student", domain: "rijschool-mos.nl", doc_root_suffix: "" } },
    { app: { app_kind: "static",  subdomain: "senne", doc_root_suffix: "" } },
    # Apex: no subdomain at all, so the document root is the webspace's httpdocs.
    { app: { app_kind: "laravel", subdomain: nil, domain: "mos-safeguards.com" } },
    { app: { app_kind: "static",  subdomain: nil, domain: "lucasvanbriemen.nl", doc_root_suffix: "",
             default_server: true, redirect_http: false } },
    { app: { app_kind: "rails",   subdomain: "login", hsts: true,
             ip_allowlist: "62.194.231.108 2001:1c00:9501:6700::/64 127.0.0.1" } },
    { app: { app_kind: "rails",   subdomain: "git", cable_path: "/cable", cable_port: 28_082 } },
    { app: { app_kind: "rails",   subdomain: "git", cable_path: "/cable" } },
    { app: { app_kind: "laravel", subdomain: "music",
             xaccel_path: "/var/www/vhosts/ltvb.nl/music.ltvb.nl/storage/audio" } },
    { app: { app_kind: "static",  subdomain: "senne", doc_root_suffix: "", tls: false } }
  ].freeze

  test "the manager's preview is byte-for-byte the config the agent writes" do
    RENDER_MATRIX.each do |row|
      app     = render_app(**row[:app])
      staging = row.fetch(:staging, false)

      assert_equal agent_site_config(app, staging: staging), NginxConfig.render(app, staging: staging),
                   "preview and written config differ for #{app.fqdn} (#{app.app_kind}, staging=#{staging})"
    end
  end

  # The variable set is the contract between the two, so compare it directly as
  # well: identical bytes from different variables would mean the template is
  # ignoring something one side sends, which is the next drift waiting to happen.
  test "both renderers derive the same variables from the same app" do
    RENDER_MATRIX.each do |row|
      app     = render_app(**row[:app])
      staging = row.fetch(:staging, false)
      site    = RENDERABLE.resolve(app.fqdn)
      params  = LtvbAgent::Schema.validate!("nginx.site.write", agent_spec(app, staging), webspaces: RENDERABLE)
      ports   = staging ? LtvbAgent::STAGING_PORTS : LtvbAgent::LIVE_PORTS

      assert_equal handlers.send(:site_variables, site, params, ports),
                   NginxConfig.new(app, staging: staging).variables,
                   "variables differ for #{app.fqdn} (#{app.app_kind}, staging=#{staging})"
    end
  end

  test "an xaccel root reaches the written config and is refused when it is not a plain path" do
    app = render_app(app_kind: "laravel", subdomain: "music",
                     xaccel_path: "/var/www/vhosts/ltvb.nl/music.ltvb.nl/storage/audio")

    assert_includes agent_site_config(app), "alias /var/www/vhosts/ltvb.nl/music.ltvb.nl/storage/audio/;"
    assert_includes agent_site_config(app), "internal;"

    [ "relative/path", "/var/www/../etc", "/var/www;deny all", "/var/www/$x", "" ].each do |value|
      refute_accepted("nginx.site.write", { "fqdn" => MANAGED, "kind" => "laravel", "xaccel" => value },
                      "accepted xaccel #{value.inspect}")
    end
  end

  # ---- the new scalar types -------------------------------------------------

  test "an enum accepts only the values the verb declared" do
    assert_equal "laravel", validate("nginx.site.write", { "fqdn" => MANAGED, "kind" => "laravel" })[:kind]
    [ "Rails", "rails ", "rails,php", "", "node", "static\n", 1, nil, true, [ "rails" ] ].each do |value|
      refute_accepted("nginx.site.write", { "fqdn" => MANAGED, "kind" => value }, "accepted kind #{value.inspect}")
    end
  end

  test "a count must be an integer inside the declared range" do
    assert_equal 5000, validate("systemd.journal", { "unit" => "nginx.service", "lines" => 5000 })[:lines]
    [ 0, -1, 5001, "200", 200.0, true, nil ].each do |value|
      refute_accepted("systemd.journal", { "unit" => "nginx.service", "lines" => value },
                      "accepted lines #{value.inspect}")
    end
  end

  test "a size is a bounded number with an optional unit" do
    assert_equal "512M", validate("systemd.unit.install", { "fqdn" => MANAGED, "memory_max" => "512M" })[:memory_max]
    assert_equal "infinity", validate("systemd.unit.install", { "fqdn" => MANAGED, "memory_max" => "infinity" })[:memory_max]
    [ "512 M", "1TB", "-1G", "1e9", "$(x)G", "9999999G", "", "1G;", "1g" ].each do |value|
      refute_accepted("systemd.unit.install", { "fqdn" => MANAGED, "memory_max" => value },
                      "accepted memory_max #{value.inspect}")
    end
  end

  test "an ip allowlist takes literal addresses and CIDRs, never a hostname" do
    entries = [ "82.161.24.7", "10.0.0.0/8", "2a01:4f8:c17:1::1", "2a01:4f8::/32" ]
    assert_equal entries, validate("nginx.site.write",
                                   { "fqdn" => MANAGED, "kind" => "rails", "allow" => entries })[:allow]

    # A hostname would make nginx resolve at load time and then quietly permit
    # whatever that name points at afterwards.
    [ "ltvb.nl", "10.0.0.0/8; deny all", "10.0.0.0/999", "10.0.0.0/8/8", "", "all",
      "82.161.24.7 ", "0x7f000001" ].each do |value|
      refute_accepted("nginx.site.write", { "fqdn" => MANAGED, "kind" => "rails", "allow" => [ value ] },
                      "accepted allow entry #{value.inspect}")
    end
  end

  test "a list is refused when it is not an array or is unreasonably long" do
    [ "10.0.0.0/8", { "0" => "10.0.0.0/8" }, nil ].each do |value|
      refute_accepted("nginx.site.write", { "fqdn" => MANAGED, "kind" => "rails", "allow" => value },
                      "accepted allow #{value.inspect}")
    end
    refute_accepted("nginx.site.write",
                    { "fqdn" => MANAGED, "kind" => "rails", "allow" => Array.new(33) { "10.0.0.1" } })
  end

  test "argv is an array whose first element is absolute, never a command string" do
    argv = [ "/opt/rbenv/versions/3.3.8/bin/bundle", "exec", "rake", "solid_queue:start" ]
    assert_equal argv, validate("systemd.unit.install",
                                { "fqdn" => MANAGED, "worker" => "jobs", "argv" => argv })[:argv]

    [ "bundle exec rake", [], [ "bundle", "exec" ], [ "./bin/rake" ], [ "" ],
      [ "/bin/true", ";" ], [ "/bin/true", 1 ], Array.new(33) { "/bin/true" } ].each do |value|
      refute_accepted("systemd.unit.install", { "fqdn" => MANAGED, "worker" => "jobs", "argv" => value },
                      "accepted argv #{value.inspect}")
    end
  end

  test "environment keys must be environment variable names" do
    assert_equal({ "RAILS_ENV" => "production" },
                 validate("systemd.unit.install", { "fqdn" => MANAGED, "env" => { "RAILS_ENV" => "production" } })[:env])

    [ { "RAILS ENV" => "x" }, { "1RAILS" => "x" }, { "RAILS-ENV" => "x" }, { "" => "x" },
      { "RAILS_ENV" => 1 }, { "RAILS_ENV" => nil }, [ "RAILS_ENV=production" ], "RAILS_ENV=production" ].each do |value|
      refute_accepted("systemd.unit.install", { "fqdn" => MANAGED, "env" => value }, "accepted env #{value.inspect}")
    end
  end

  test "an environment block that would outgrow a unit file is refused" do
    refute_accepted("systemd.unit.install",
                    { "fqdn" => MANAGED, "env" => (1..65).to_h { |i| [ "K#{i}", "v" ] } })
    refute_accepted("systemd.unit.install",
                    { "fqdn" => MANAGED, "env" => { "BIG" => "x" * (64 * 1024) } })
  end

  # ---- unit names -----------------------------------------------------------

  test "a unit name is a name, never something systemctl could read as a path" do
    %w[nginx.service ltvb-apps-jobs.service ltvb-app@git.ltvb.nl.service
       git-ltvb-cable.service certbot.timer php8.3-fpm.service postfix@-.service].each do |unit|
      assert_equal unit, LtvbAgent::Units.name!(:unit, unit)
    end

    [ "/etc/systemd/system/evil.service", "../evil.service", "ltvb-app@..service",
      "evil", "evil.mount", "evil.service ", "Evil.service", "-evil.service",
      "evil.service\nnginx.service", "ltvb-app@evil.service.", "evil.service;reboot" ].each do |unit|
      assert_raises(LtvbAgent::Invalid, "accepted unit #{unit.inspect}") { LtvbAgent::Units.name!(:unit, unit) }
    end
  end

  test "the legacy allowlist is an enumeration, not a looser pattern" do
    # php8.3-fpm.service has a dot in the NAME half, which the pattern refuses.
    # Widening the pattern to admit it would admit every name shaped like it.
    assert_raises(LtvbAgent::Invalid) { LtvbAgent::Units.name!(:unit, "php8.5-fpm.service") }
    assert_equal "php8.3-fpm.service", LtvbAgent::Units.name!(:unit, "php8.3-fpm.service")
  end

  test "reading a unit is wide, but acting on one is a short list of shapes" do
    %w[ltvb-app@git.ltvb.nl.service ltvb-apps-jobs.service ltvb-nginx.service
       git-ltvb-jobs.service php8.3-fpm.service].each do |unit|
      assert_equal unit, LtvbAgent::Units.controllable!(:unit, unit)
    end

    # Readable, and deliberately not controllable: stopping any of these is an
    # outage the manager has no business being able to cause on its own.
    %w[ssh.service systemd-journald.service apache2.service postfix.service
       dovecot.service redis.service bind9.service].each do |unit|
      assert_equal unit, LtvbAgent::Units.name!(:unit, unit)
      error = assert_raises(LtvbAgent::Invalid, "controllable: #{unit}") { LtvbAgent::Units.controllable!(:unit, unit) }
      assert_equal "not_manageable", error.code
    end
  end

  test "the agent refuses to be asked to stop the agent" do
    # The call that did it would be the last one answered, and nothing left
    # running could start it again.
    assert_equal "ltvb-agent.service", LtvbAgent::Units.name!(:unit, "ltvb-agent.service")
    assert_raises(LtvbAgent::Invalid) { LtvbAgent::Units.controllable!(:unit, "ltvb-agent.service") }
    refute_accepted("systemd.restart", { "unit" => "ltvb-agent.service" })
  end

  test "the read-only systemd verbs observe shared daemons but not every unit" do
    # nginx is a daemon whose health the manager legitimately reports on, but
    # cannot control directly (it reloads through nginx.reload's validate-first
    # contract instead).
    assert_equal "nginx.service", validate("systemd.status", { "unit" => "nginx.service" })[:unit]
    assert_equal "nginx.service", validate("systemd.journal", { "unit" => "nginx.service" })[:unit]

    %w[systemd.restart systemd.enable systemd.disable systemd.unit.remove].each do |verb|
      refute_accepted(verb, { "unit" => "nginx.service" }, "#{verb} accepted nginx.service")
    end
  end

  # Reading a journal is not harmless, so status/journal use an allowlist rather
  # than "any well-formed unit name".
  test "the read-only verbs refuse journals that leak credentials or the audit trail" do
    # sshd logs usernames and source addresses for every login and every failed
    # attempt; the agent's own journal is the audit trail of every privileged
    # call made through it, including the parameters of failures.
    %w[ssh.service sshd.service ltvb-agent.service systemd-logind.service].each do |unit|
      %w[systemd.status systemd.journal].each do |verb|
        refute_accepted(verb, { "unit" => unit }, "#{verb} accepted #{unit}")
      end
    end
  end

  test "the read-only verbs still cover everything the manager runs" do
    %w[ltvb-app@git.ltvb.nl.service ltvb-apps-jobs.service php8.3-fpm.service].each do |unit|
      assert_equal unit, validate("systemd.status", { "unit" => unit })[:unit]
    end
  end

  # ---- the render spec ------------------------------------------------------

  test "no verb accepts config text, a filesystem path or a unit file body" do
    # The property the whole design rests on. If this fails, some verb grew a
    # field that lets the web user author what root parses. http.check's `path`
    # is exempt by TYPE, not by name: a request path is a string in an HTTP
    # request line, and it never reaches the filesystem.
    forbidden = %w[path root dir directory file config conf text body content
                   unit_file exec_start command cmd script sql]
    LtvbAgent::Schema::VERBS.each do |verb, spec|
      overlap = spec[:params].reject { |_, rules| rules[:type] == :url_path }.keys.map(&:to_s) & forbidden
      assert_empty overlap, "#{verb} takes #{overlap.join(', ')} — root must derive that, not receive it"
    end
  end

  test "a rendered vhost derives every path from the webspace table" do
    handlers = LtvbAgent::Handlers.new(webspaces: WEBSPACES, config: LtvbAgent::Config::DEFAULT)
    params = validate("nginx.site.write", { "fqdn" => MANAGED, "kind" => "rails", "suffix" => "public" })
    config = handlers.send(:render_site, WEBSPACES.resolve(MANAGED), params)

    assert_includes config, "server_name #{MANAGED};"
    assert_includes config, "root /var/www/vhosts/ltvb.nl/git.ltvb.nl/public;"
    assert_includes config, "access_log /var/log/ltvb/sites/git.ltvb.nl/access.log ltvb_scrubbed;"
    assert_includes config, "proxy_pass http://unix:/run/ltvb-app/git.ltvb.nl/puma.sock:;"
    assert_includes config, "ssl_certificate     /etc/letsencrypt/live/git.ltvb.nl/fullchain.pem;"
    assert_equal config.count("{"), config.count("}"), "an unbalanced render is a config nginx refuses to load"
  end

  test "a rendered vhost with tls off has no https block and no redirect loop" do
    handlers = LtvbAgent::Handlers.new(webspaces: WEBSPACES, config: LtvbAgent::Config::DEFAULT)
    params = validate("nginx.site.write", { "fqdn" => MANAGED, "kind" => "static", "tls" => false })
    config = handlers.send(:render_site, WEBSPACES.resolve(MANAGED), params)

    assert_equal 1, config.scan(/^server \{/).size
    refute_includes config, "return 301 https://"
    refute_includes config, "ssl_certificate"
  end

  test "staging renders its own ports, its own log files and no HSTS" do
    handlers = LtvbAgent::Handlers.new(webspaces: WEBSPACES, config: LtvbAgent::Config::DEFAULT)
    params = validate("nginx.site.write",
                      { "fqdn" => MANAGED, "kind" => "rails", "staging" => true, "hsts" => true })
    config = handlers.send(:render_site, WEBSPACES.resolve(MANAGED), params)

    assert_includes config, "listen 9443 ssl;"
    assert_includes config, "staging-access.log"
    # HSTS is scoped to the host and not the port, so a max-age sent from :9443
    # would pin the browser for the live site too.
    refute_includes config, "Strict-Transport-Security"
    assert_includes config, "return 301 https://$host:9443$request_uri;"
  end

  test "a unit name is derived from the fqdn, never sent" do
    handlers = LtvbAgent::Handlers.new(webspaces: WEBSPACES, config: LtvbAgent::Config::DEFAULT)
    site = WEBSPACES.resolve(MANAGED)

    assert_equal "ltvb-app@git.ltvb.nl.service", handlers.send(:unit_name, site, nil)
    assert_equal "ltvb-jobs-git-ltvb-nl.service", handlers.send(:unit_name, site, "jobs")
  end

  test "a rendered unit runs as the webspace owner and escapes what systemd expands" do
    handlers = LtvbAgent::Handlers.new(webspaces: WEBSPACES, config: LtvbAgent::Config::DEFAULT)
    site = WEBSPACES.resolve(MANAGED)
    params = validate("systemd.unit.install",
                      { "fqdn" => MANAGED, "ruby" => "3.3.8", "workdir" => "current",
                        "env" => { "SECRET" => 'a%b$c"d' } })
    unit = handlers.send(:render_unit, site, "ltvb-app@#{MANAGED}.service", params)

    assert_includes unit, "User=ltvb"
    refute_includes unit, "User=root"
    assert_includes unit, "WorkingDirectory=/var/www/vhosts/ltvb.nl/git.ltvb.nl/current"
    assert_includes unit, "RuntimeDirectory=ltvb-app/git.ltvb.nl"
    # `%` doubled (systemd expands %h/%i), the quote backslashed, and `$` left
    # alone in Environment= because systemd does not expand it there.
    assert_includes unit, %(Environment="SECRET=a%%b$c\\"d")
    assert_includes unit, %("/opt/rbenv/versions/3.3.8/bin/bundle")
    refute_includes unit, "bash"
  end

  test "an app unit will not take a command and a worker unit will not go without one" do
    handlers = LtvbAgent::Handlers.new(webspaces: WEBSPACES, config: LtvbAgent::Config::DEFAULT)
    site = WEBSPACES.resolve(MANAGED)

    smuggled = validate("systemd.unit.install",
                        { "fqdn" => MANAGED, "ruby" => "3.3.8", "argv" => [ "/bin/sh", "-c", "id" ] })
    assert_raises(LtvbAgent::Invalid) { handlers.send(:render_unit, site, "ltvb-app@x.service", smuggled) }

    headless = validate("systemd.unit.install", { "fqdn" => MANAGED, "worker" => "jobs" })
    assert_raises(LtvbAgent::Invalid) { handlers.send(:render_unit, site, "ltvb-jobs-x.service", headless) }

    keyless = validate("systemd.unit.install", { "fqdn" => MANAGED })
    assert_raises(LtvbAgent::Invalid) { handlers.send(:render_unit, site, "ltvb-app@x.service", keyless) }
  end

  test "dir.ensure names a kind, and the kind names a directory the agent already knew" do
    assert_equal "logs", validate("dir.ensure", { "fqdn" => MANAGED })[:kind]
    [ "/var/log", "logs/../..", "tmp", "", "LOGS" ].each do |kind|
      refute_accepted("dir.ensure", { "fqdn" => MANAGED, "kind" => kind }, "accepted kind #{kind.inspect}")
    end
    assert_equal LtvbAgent::Handlers::DIR_KINDS.keys.sort,
                 LtvbAgent::Schema::VERBS.dig("dir.ensure", :params, :kind, :values).sort
  end

  test "the php version is an enum, so it can never become a path segment" do
    assert_equal "8.2", validate("fpm.pool.write", { "fqdn" => MANAGED, "php" => "8.2" })[:php]
    [ "8.5", "../../etc", "8.3/../..", "8", "" ].each do |value|
      refute_accepted("fpm.pool.write", { "fqdn" => MANAGED, "php" => value }, "accepted php #{value.inspect}")
    end
  end

  # ---- exec -----------------------------------------------------------------

  test "a command is refused unless argv zero is an absolute path" do
    [ "systemctl", "./deploy", "../bin/sh", "" ].each do |command|
      error = assert_raises(LtvbAgent::Failure) { LtvbAgent::Exec.run([ command, "status" ], timeout: 1) }
      assert_match(/must be absolute/, error.message)
    end
  end

  test "a command that outruns its deadline is killed and reported as timed out" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = LtvbAgent::Exec.run([ "/bin/sh", "-c", "sleep 60" ], timeout: 1)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert result.timed_out
    refute result.ok
    assert_operator elapsed, :<, 20, "the child's process group must be killed, not waited on"
  end

  test "a command's exit status and streams are reported" do
    ok = LtvbAgent::Exec.run([ "/bin/echo", "hello" ], timeout: 10)
    assert ok.ok
    assert_equal "hello\n", ok.out

    bad = LtvbAgent::Exec.run([ "/bin/sh", "-c", "echo boom >&2; exit 3" ], timeout: 10)
    refute bad.ok
    assert_equal "boom\n", bad.err
  end

  # ---- schema hygiene -------------------------------------------------------

  test "every verb in the schema has a handler" do
    handlers = LtvbAgent::Handlers.new(webspaces: WEBSPACES, config: LtvbAgent::Config::DEFAULT)
    missing = LtvbAgent::Schema.verbs.reject { |verb| handlers.handles?(verb) }
    assert_empty missing, "verbs declared with no implementation: #{missing.join(', ')}"
  end

  test "every declared parameter uses a type the coercer implements" do
    known = %i[label version relpath url_path config_path text line bool port size argv env
               ip_list enum count unit managed_unit domain fqdn]
    LtvbAgent::Schema::VERBS.each do |verb, spec|
      spec[:params].each do |name, rules|
        assert_includes known, rules[:type], "#{verb}.#{name} declares unknown type #{rules[:type].inspect}"
      end
    end
  end

  test "every enum and count declares the bounds its coercer reads" do
    # coerce! fetches these, so a schema entry missing one is a 500 on the first
    # call rather than a startup error — cheap to catch here instead.
    LtvbAgent::Schema::VERBS.each do |verb, spec|
      spec[:params].each do |name, rules|
        case rules[:type]
        when :enum
          assert_kind_of Array, rules[:values], "#{verb}.#{name} is an enum with no values"
          refute_empty rules[:values], "#{verb}.#{name} is an enum with an empty value list"
        when :count
          assert_kind_of Integer, rules[:min], "#{verb}.#{name} is a count with no min"
          assert_kind_of Integer, rules[:max], "#{verb}.#{name} is a count with no max"
        end
      end
    end
  end

  test "every declared default is a value its own type would have accepted" do
    # A default bypasses coercion — it is trusted because the agent wrote it —
    # so nothing but this test stops a typo'd default from reaching a handler.
    checked = 0
    LtvbAgent::Schema::VERBS.each do |verb, spec|
      spec[:params].each do |name, rules|
        next unless rules.key?(:default)

        checked += 1
        LtvbAgent::Schema.coerce!(name, rules[:default], rules, WEBSPACES)
      rescue LtvbAgent::Invalid => e
        flunk("#{verb}.#{name} defaults to #{rules[:default].inspect}, which its own type rejects: #{e.message}")
      end
    end
    assert_operator checked, :>, 10
  end

  test "every verb declares a timeout, a mutating flag and a summary" do
    LtvbAgent::Schema::VERBS.each do |verb, spec|
      assert_kind_of Integer, spec[:timeout], "#{verb} has no timeout"
      assert_operator spec[:timeout], :>, 0, "#{verb} has a non-positive timeout"
      assert_includes [ true, false ], spec[:mutating], "#{verb} does not say whether it mutates"
      assert spec[:summary].present?, "#{verb} has no summary"
    end
  end

  test "verb names stay in the dotted namespace the client and audit log assume" do
    LtvbAgent::Schema.verbs.each do |verb|
      assert_match(/\A[a-z][a-z0-9]*(?:\.[a-z][a-z0-9_]*)+\z|\Aping\z/, verb)
    end
  end

  test "the shipped verb set covers everything needed to serve a site without plesk" do
    # The list is asserted whole rather than by count: this is the agent's entire
    # root surface, and a verb appearing in it is a decision, not a detail.
    assert_equal %w[
      ping
      plesk.domains plesk.subdomain.create plesk.subdomain.docroot plesk.ruby.enable
      plesk.reconfigure plesk.subdomain.remove jobs.restart
      sites.discover services.discover http.check
      nginx.site.write nginx.site.remove nginx.test nginx.reload
      systemd.unit.install systemd.unit.remove systemd.daemon_reload
      systemd.enable systemd.disable systemd.restart systemd.status systemd.journal
      fpm.pool.write fpm.reload dir.ensure
    ].sort, LtvbAgent::Schema.verbs.sort
  end

  test "everything that writes a file or moves a service is marked mutating" do
    mutating = LtvbAgent::Schema::VERBS.select { |_, spec| spec[:mutating] }.keys
    assert_equal %w[plesk.subdomain.create plesk.subdomain.docroot plesk.ruby.enable
                    plesk.reconfigure plesk.subdomain.remove jobs.restart
                    nginx.site.write nginx.site.remove nginx.reload
                    systemd.unit.install systemd.unit.remove systemd.daemon_reload
                    systemd.enable systemd.disable systemd.restart
                    fpm.pool.write fpm.reload dir.ensure].sort, mutating.sort
  end

  test "a verb that writes into a webspace is refused on the four read-only ones" do
    # nginx.site.write and friends inherit the ALLOWED_DOMAINS policy the bash
    # wrapper had. Serving the customer webspaces from nginx is a root edit of
    # webspaces.json, deliberately — not something the manager can ask for.
    {
      "nginx.site.write"     => { "fqdn" => READ_ONLY, "kind" => "static" },
      "nginx.site.remove"    => { "fqdn" => READ_ONLY },
      "systemd.unit.install" => { "fqdn" => READ_ONLY, "ruby" => "3.3.8" },
      "fpm.pool.write"       => { "fqdn" => READ_ONLY },
      "dir.ensure"           => { "fqdn" => READ_ONLY }
    }.each do |verb, params|
      error = assert_raises(LtvbAgent::Invalid, "#{verb} was not gated") { validate(verb, params) }
      assert_equal "not_manageable", error.code, verb
    end
  end

  # ---- the ping contract ----------------------------------------------------

  test "ping answers with the version, the protocol and the verb list" do
    handlers = LtvbAgent::Handlers.new(webspaces: WEBSPACES, config: LtvbAgent::Config::DEFAULT)
    data = handlers.call("ping", {}, 5)[:data]

    assert_equal LtvbAgent::PROTOCOL, data["protocol"]
    assert_equal LtvbAgent::VERSION, data["agent_version"]
    assert_equal LtvbAgent::Schema.verbs, data["verbs"]
  end

  test "the client and the daemon agree on the protocol number" do
    # The agent is installed by root and is never updated by an app deploy, so
    # these two can drift. When they do, every call must fail loudly — and this
    # test is what stops them drifting inside one commit.
    assert_equal LtvbAgent::PROTOCOL, Agent::PROTOCOL
  end

  test "the client Result is drop-in compatible with PrivilegedShell's" do
    shell = PrivilegedShell::Result.new(true, "out", "err")
    agent = Agent::Result.new(true, "out", "err", { "k" => 1 }, nil)

    assert_equal shell.output, agent.output
    assert_equal [ shell.ok, shell.out, shell.err ], [ agent.ok, agent.out, agent.err ]
    assert_equal "out", Agent::Result.new(true, "out", "", nil, nil).output
  end

  # ---- dispatch, locking and the audit contract ----------------------------

  # The socket needs SO_PEERCRED, which is Linux-only, but everything behind it
  # is not — dispatch is called directly here so the audit ordering and the
  # lock are covered on any machine.
  class RecordingAudit
    attr_reader :events

    def initialize = @events = []
    def write(event) = @events << event
    def close = nil
  end

  PEER = { "pid" => 1234, "uid" => 4321, "user" => "ltvb-manager" }.freeze

  def with_server
    audit = RecordingAudit.new
    Dir.mktmpdir("ltvb-agent-server") do |dir|
      server = LtvbAgent::Server.new(
        config: LtvbAgent::Config::DEFAULT.merge("allowed_users" => [ Etc.getpwuid(Process.uid).name ]),
        webspaces: WEBSPACES, audit: audit,
        socket_path: File.join(dir, "agent.sock"), lock_path: File.join(dir, "lock")
      )
      yield server, audit
    end
  end

  test "a refused request is audited without its rejected values" do
    with_server do |server, audit|
      response = server.dispatch("http.check", { "fqdn" => "attacker.example\nrm -rf /" }, PEER)

      refute response["ok"]
      assert_equal "schema", response["code"]
      assert_equal 1, audit.events.size
      assert_equal "done", audit.events.first["phase"]
      assert_equal({ "rejected_keys" => [ "fqdn" ] }, audit.events.first["params"])
      refute_includes JSON.generate(audit.events), "rm -rf"
    end
  end

  test "a mutating call is audited before the work as well as after" do
    with_server do |server, audit|
      # No plesk binary off-server, so the call fails — which is the point: the
      # "start" line must already be on disk by the time the work explodes.
      response = server.dispatch("plesk.reconfigure", { "fqdn" => MANAGED }, PEER)

      refute response["ok"]
      assert_equal "exec", response["code"]
      assert_equal %w[start done], audit.events.map { |e| e["phase"] }
      assert_equal({ "fqdn" => MANAGED }, audit.events.first["params"])
      assert_equal PEER, audit.events.first["peer"]
    end
  end

  test "a read-only verb is audited once and never takes the lock" do
    with_server do |server, audit|
      response = server.dispatch("http.check", { "fqdn" => MANAGED, "port" => 1, "tls" => false }, PEER)

      assert response["ok"], response["err"]
      assert_nil response["data"]["code"], "nothing is listening on port 1"
      assert_equal [ "done" ], audit.events.map { |e| e["phase"] }
    end
  end

  test "an unmanageable webspace is refused before any lock or work" do
    with_server do |server, audit|
      response = server.dispatch("plesk.reconfigure", { "fqdn" => READ_ONLY }, PEER)

      assert_equal "not_manageable", response["code"]
      assert_equal [ "done" ], audit.events.map { |e| e["phase"] }, "no start line: nothing was attempted"
    end
  end

  test "the mutating lock is released so a second call can take it" do
    with_server do |server, _audit|
      assert_equal :first, server.with_lock { :first }
      assert_equal :second, server.with_lock { :second }
    end
  end

  # ---- client behaviour against a stand-in agent ----------------------------

  # A throwaway socket that speaks the protocol. Exercises the client's framing,
  # handshake and timeout handling without needing root or the real daemon.
  # `responder` returns the reply hash, or nil to say nothing at all.
  def with_fake_agent(responder)
    Dir.mktmpdir("ltvb-agent-sock") do |dir|
      path = File.join(dir, "agent.sock")
      server = UNIXServer.new(path)
      thread = Thread.new do
        while (conn = server.accept)
          while (line = conn.gets("\n"))
            reply = responder.call(JSON.parse(line))
            conn.write("#{JSON.generate(reply)}\n") if reply
          end
          conn.close
        end
      rescue IOError, Errno::ECONNRESET, Errno::EBADF
        nil
      end
      thread.report_on_exception = false

      begin
        with_socket_path(path) { yield }
      ensure
        thread.kill
        server.close
      end
    end
  end

  # Minitest's `stub` lives in minitest/mock, which is not in this app's bundle
  # and adding a gem for one helper is not worth it.
  def with_socket_path(path)
    original = Agent.method(:socket_path)
    Agent.define_singleton_method(:socket_path) { path }
    Agent.reset!
    yield
  ensure
    Agent.define_singleton_method(:socket_path, original)
    Agent.reset!
  end

  def ok_reply(request, data: nil, out: "")
    { "id" => request["id"], "ok" => true, "out" => out, "err" => "", "data" => data }
  end

  def ping_reply(request, protocol: Agent::PROTOCOL, verbs: LtvbAgent::Schema.verbs)
    ok_reply(request, data: { "agent_version" => "1.0.0", "protocol" => protocol, "verbs" => verbs })
  end

  test "the client handshakes and then round-trips a call" do
    responder = lambda do |request|
      request["verb"] == "ping" ? ping_reply(request) : ok_reply(request, data: { "code" => 200 })
    end

    with_fake_agent(responder) do
      result = Agent.call("http.check", fqdn: MANAGED)
      assert result.ok
      assert_equal 200, result.data["code"]
    end
  end

  test "the client refuses to talk to an agent speaking a different protocol" do
    with_fake_agent(->(request) { ping_reply(request, protocol: Agent::PROTOCOL + 1) }) do
      result = Agent.call("http.check", fqdn: MANAGED)
      refute result.ok
      assert_equal "protocol", result.code
      assert_match(/reinstall/, result.err)
    end
  end

  test "the client refuses a verb the running agent does not implement" do
    with_fake_agent(->(request) { ping_reply(request, verbs: %w[ping]) }) do
      result = Agent.call("nginx.write", fqdn: MANAGED)
      refute result.ok
      assert_equal "unknown_verb", result.code
    end
  end

  test "an error from the agent comes back as a failed Result, not an exception" do
    responder = lambda do |request|
      next ping_reply(request) if request["verb"] == "ping"

      { "id" => request["id"], "ok" => false, "out" => "", "err" => "fqdn: not a hostname", "code" => "schema" }
    end

    with_fake_agent(responder) do
      result = Agent.call("http.check", fqdn: MANAGED)
      refute result.ok
      assert_equal "schema", result.code
      assert_equal "fqdn: not a hostname", result.output
    end
  end

  test "a silent agent times out instead of hanging the worker" do
    with_fake_agent(->(request) { request["verb"] == "ping" ? ping_reply(request) : nil }) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Agent.call("http.check", timeout: 1, fqdn: MANAGED)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      refute result.ok
      assert_operator elapsed, :<, 15
    end
  end

  test "a missing socket is a failed Result with a code, not a raised error" do
    with_socket_path("/nonexistent/ltvb-agent.sock") do
      result = Agent.call("http.check", fqdn: MANAGED)
      refute result.ok
      assert_equal "unavailable", result.code
      refute Agent.available?
    end
  end

  test "an oversized request is refused before a connection is opened" do
    # The path does not exist, so reaching the socket at all would raise ENOENT.
    # Getting "oversize" back proves the size check ran first.
    with_socket_path("/nonexistent/ltvb-agent.sock") do
      result = Agent.send(:request, "sites.write", { blob: "x" * (Agent::MAX_REQUEST_BYTES + 1) }, 5)
      assert_equal "oversize", result.code
    end
  end
end
