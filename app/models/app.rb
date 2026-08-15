class App < ApplicationRecord
  # rails/laravel/php/static are served over HTTP; cron is a Laravel app with a
  # schedule but no vhost; repo is a plain checkout (e.g. the shared ui-components
  # library) that is pulled and built but never served.
  APP_KINDS = %w[rails laravel php static cron repo].freeze

  # Kinds that run a Ruby/rbenv toolchain and can host a rails console.
  RUBY_KINDS = %w[rails].freeze
  # Kinds built with composer and served through PHP-FPM.
  PHP_KINDS  = %w[laravel php cron].freeze
  # Kinds that get a vhost and a health check.
  SERVED_KINDS = %w[rails laravel php static].freeze

  PRIMARY_DB_KINDS = %w[sqlite external].freeze

  # Every webspace on the box is a directory here.
  VHOSTS_ROOT = "/var/www/vhosts".freeze

  # Plesk gives every subdomain its own directory inside the webspace, named
  # after the fqdn. An apex domain gets no such directory — Apache serves it
  # straight out of the webspace's httpdocs/, which is why six of the 22 live
  # hostnames (ltvb.nl, lucasvanbriemen.nl, djtim.eu, rijschool-mos.nl,
  # mos-safeguards.com, voordezorgmanagement.nl) have no subdomain at all.
  APEX_WWW_DIR = "httpdocs".freeze

  # The six webspaces on this host. Each is a separate subscription with its own
  # uid, so an app lives in exactly one of them and cannot be created anywhere
  # else. (The privileged agent keeps its own authoritative copy of this list —
  # it must never trust a domain that came from the database.)
  WEBSPACE_DOMAINS = %w[
    ltvb.nl lucasvanbriemen.nl djtim.eu
    rijschool-mos.nl mos-safeguards.com voordezorgmanagement.nl
  ].freeze

  # The directory a deploy checks out into, relative to the webspace root: one
  # plain name, never a path. Anchored so an empty value, a "/" or a ".." from a
  # record that skipped validation (a console update_column, a legacy row) can
  # never walk the deploy runner out of the app's own directory.
  WWW_DIR_FORMAT = /\A[a-z0-9][a-z0-9.-]*\z/

  # Document root relative to the app: plain segments only, no leading slash and
  # no "..", because it is joined onto app_path and handed to nginx as `root`.
  DOC_ROOT_SUFFIX_FORMAT = %r{\A[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*\z}

  has_many :deployments, -> { order(created_at: :desc) }, dependent: :destroy
  has_many :exception_groups, dependent: :destroy
  has_many :console_sessions, dependent: :destroy
  has_many :webhook_deliveries, -> { order(created_at: :desc) }, dependent: :destroy
  has_many :releases, -> { order(created_at: :desc) }, dependent: :destroy

  # A worker or a cron entry can exist without an app (the Kokoro TTS server,
  # root's own crontab), so the child keeps an optional app_id. Nullify rather
  # than destroy: untracking an app must not silently stop a systemd unit or
  # delete a schedule that is still running on the box.
  has_many :process_services, dependent: :nullify
  has_many :scheduled_jobs, dependent: :nullify

  # Authenticates POSTs to /api/exceptions from this app's error reporter.
  before_create { self.ingest_token ||= SecureRandom.hex(24) }
  # Selects which app a webhook is for. Not a credential — the HMAC is.
  before_create { self.webhook_token ||= SecureRandom.hex(24) }

  # Secrets are stored encrypted at rest (keys configured from .env in
  # config/initializers/active_record_encryption.rb).
  encrypts :master_key
  encrypts :env_text
  encrypts :webhook_secret

  validates :name, presence: true
  validates :app_kind, inclusion: { in: APP_KINDS }
  validates :primary_db_kind, inclusion: { in: PRIMARY_DB_KINDS }
  validates :git_repo_url, presence: true

  # Anything with a vhost needs a resolvable hostname; repos and cron apps don't.
  # The subdomain is optional because an apex domain has none — its fqdn IS the
  # domain — but the domain is not: it names the webspace the files live in.
  with_options if: :served? do
    validates :domain, presence: true
    validates :subdomain, uniqueness: { scope: :domain }
    validates :subdomain, format: { with: /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/,
                                    message: "must be a valid hostname label" },
                          allow_blank: true
    validates :domain, format: { with: /\A[a-z0-9.-]+\z/ }
  end

  validates :doc_root_suffix, format: { with: DOC_ROOT_SUFFIX_FORMAT,
                                        message: "must be a relative path like \"public\"" },
                              allow_blank: true

  # Clearing a subdomain does not rename a site, it re-points app_path at the
  # webspace's httpdocs/ — the apex site's populated directory. The deploy
  # runner refuses such a row anyway (see undeployable_reason), but the edit
  # itself should not be silent: the two signals must be given together.
  validate :subdomain_is_not_cleared_by_accident, on: :update

  # An apex site has no subdomain, and only a vhost serves a domain out of
  # httpdocs/ — a confirmation that contradicts either is a mis-tick, and the
  # thing it authorises is a `git reset --hard` in another site's directory.
  validate :apex_confirmation_matches_the_record, if: :apex_confirmed?

  validates :ruby_version, presence: true, if: :ruby?
  validates :php_version, presence: true, if: :php?

  # Written into nginx as an allow-list. Anything that isn't an address or CIDR
  # would be interpolated into a config the web server then parses as root.
  validate :ip_allowlist_entries_are_addresses, if: -> { ip_allowlist.present? }

  # The serving customisations below all reach an nginx config that root parses.
  # NginxConfig re-validates every one of them at render time and refuses to
  # write a file if anything is off — these are the early, human-facing checks,
  # so a typo is a form error instead of a vhost that silently fails to render.
  validates :cable_path, format: { with: %r{\A/[a-zA-Z0-9._~/-]*\z},
                                   message: "must be a plain URI path like \"/cable\"" },
                         allow_blank: true
  validates :cable_port, numericality: { only_integer: true, in: 1..65_535 }, allow_nil: true
  validates :xaccel_path, format: { with: %r{\A/[a-zA-Z0-9._@+/-]*\z},
                                    message: "must be an absolute filesystem path" },
                          allow_blank: true
  validate :xaccel_path_has_no_parent_segment, if: -> { xaccel_path.present? }

  # Repos live at a custom path and are git-only (nothing to upload-build).
  with_options if: :repo? do
    validates :deploy_path, presence: true
  end

  normalizes :subdomain, :domain, with: ->(v) { v.to_s.strip.downcase.presence }
  normalizes :deploy_path, with: ->(v) { v.to_s.strip.chomp("/").presence }
  normalizes :cable_path, :xaccel_path, with: ->(v) { v.to_s.strip.chomp("/").presence }

  # An apex domain is its own fqdn; everything else prefixes its hostname label.
  # Joined from what is present, so a half-filled record resolves to "" or
  # "example" rather than ".ltvb.nl" — which reads like a wildcard, is not a
  # hostname, and made every apex site unrepresentable.
  def fqdn
    [ subdomain.presence, domain.presence ].compact.join(".")
  end

  # Whether this app serves the domain itself rather than a subdomain of it.
  # Deliberately structural — "has no subdomain" — and not a function of
  # serves_http, the kind, or the apex_confirmed flag: reading an app's logs,
  # its document root and its unit name must never depend on a toggle, and an
  # imported apex row has to point at its real directory from the moment it is
  # recorded. Whether such a row may be WRITTEN to is a different question,
  # answered by apex_confirmed in undeployable_reason.
  def apex? = subdomain.blank? && domain.present?

  # Guard for the deploy runner, which does `git reset --hard` in app_path.
  # Every branch here is a record whose path cannot be trusted to be this app's
  # own directory:
  #   * no domain at all — app_path would be "/var/www/vhosts//…", i.e. inside
  #     the shared webspace root that eight internet-facing apps live in;
  #   * a blank subdomain nobody confirmed — an apex site and a subdomain app
  #     whose subdomain was wiped are the same row, and both resolve to the
  #     webspace's httpdocs/. Reading is fine either way; writing is not, so
  #     the flag has to say the blank is deliberate;
  #   * a blank subdomain on a kind that never gets a vhost — the apex layout
  #     exists only because Apache serves a *domain* out of httpdocs/, so a
  #     cron app or an orphan without a subdomain is a broken row pointing at
  #     the apex site's files, whatever the flag says;
  #   * a path segment that is not a single plain directory name — a "/" or a
  #     ".." smuggled into either half by a record that skipped validation
  #     (note that an apex app's www_dir is the constant "httpdocs", so its
  #     domain is the only segment left to check).
  # Validations normally prevent all of these, but a bad row (legacy, console,
  # blank import) must never reach the filesystem. Returns a reason, or nil.
  def undeployable_reason
    if repo?
      "no checkout path configured" if deploy_path.blank?
    elsif domain.blank?
      "missing domain (resolved fqdn would be #{fqdn.inspect})"
    elsif apex? && !vhost_kind?
      "missing subdomain: a #{app_kind} app has no vhost, so it cannot be the apex site in #{APEX_WWW_DIR}/"
    elsif apex? && !apex_confirmed?
      "missing subdomain: deploying would write to #{app_path}, the apex site's files. " \
      "Confirm this app IS #{domain} if that is what it is."
    elsif (bad = [ domain, www_dir ].find { |segment| !segment.match?(WWW_DIR_FORMAT) })
      "resolved path segment #{bad.inspect} is not a plain directory name under #{VHOSTS_ROOT}"
    end
  end

  # Plesk lays every domain's files out under /var/www/vhosts/<domain>.
  def webspace_root
    "#{VHOSTS_ROOT}/#{domain}"
  end

  # This app's own directory inside the webspace. Plesk names a subdomain's
  # directory after its fqdn but never creates <domain>/<domain> for the domain
  # itself — the apex site is httpdocs/, which is why that name is a constant
  # here and excluded from ServerInventory's list of webspace scaffolding.
  def www_dir
    apex? ? APEX_WWW_DIR : fqdn
  end

  # Where the code lives on disk: a repo's explicit checkout path, otherwise the
  # app's directory in its webspace.
  def app_path
    repo? ? deploy_path : "#{webspace_root}/#{www_dir}"
  end

  # Where the web server points. Rails and Laravel serve from public/; a plain
  # PHP or static site serves from the app root, and pointing it at a
  # non-existent public/ is exactly the misconfiguration this tool exists to
  # prevent — so the suffix is per-app data, not a constant.
  def public_path
    doc_root_suffix.presence ? File.join(app_path, doc_root_suffix) : app_path
  end

  # www-root relative to the webspace, e.g. "git.ltvb.nl/public" for a subdomain
  # and "httpdocs/public" for an apex site like mos-safeguards.com.
  def relative_www_root
    doc_root_suffix.presence ? "#{www_dir}/#{doc_root_suffix}" : www_dir
  end

  def rbenv_root
    "#{webspace_root}/.rbenv"
  end

  # The system user a deploy must run as. Only ltvb.nl's apps run as `ltvb`;
  # the other five subscriptions each own their own webspace, and building as
  # the wrong user leaves unwritable files behind.
  def deploy_user
    runtime_user.presence || "ltvb"
  end

  def rails_app? = app_kind == "rails"
  def repo?      = app_kind == "repo"
  def ruby?      = RUBY_KINDS.include?(app_kind)
  def php?       = PHP_KINDS.include?(app_kind)
  # A kind Plesk gives a vhost. `served?` narrows that with the serves_http
  # toggle; the apex layout follows from the kind alone, so that toggle can
  # never move an app's files on disk.
  def vhost_kind? = SERVED_KINDS.include?(app_kind)
  def served?    = vhost_kind? && serves_http?
  def archived?  = archived_at.present?

  # Space-separated addresses/CIDRs, rendered into the web server config.
  def ip_allowlist_entries
    ip_allowlist.to_s.split(/[\s,]+/).reject(&:blank?)
  end

  # Follow-up shell commands for a repo: one per non-blank, non-comment line.
  def post_deploy_command_list
    post_deploy_commands.to_s.lines.map(&:strip)
                        .reject { |l| l.empty? || l.start_with?("#") }
  end

  def last_deployment
    deployments.first
  end

  def url
    "https://#{fqdn}/"
  end

  def health_check_url
    URI.join(url, health_check_path.presence || "/").to_s
  end

  private

  def subdomain_is_not_cleared_by_accident
    return if subdomain.present? || subdomain_was.blank? || apex_confirmed?

    errors.add(:subdomain, "cannot be cleared: this app would then point at " \
                           "#{webspace_root}/#{APEX_WWW_DIR}, the apex site's files. " \
                           "Confirm the apex domain in the same edit if that is deliberate.")
  end

  def apex_confirmation_matches_the_record
    errors.add(:apex_confirmed, "is only for the domain itself — remove the subdomain") if subdomain.present?
    errors.add(:apex_confirmed, "needs a domain") if domain.blank?
    errors.add(:apex_confirmed, "is only possible for a kind that gets a vhost") unless vhost_kind?
  end

  # `alias` and `root` follow a .. out of the webspace without needing a single
  # character of punctuation.
  def xaccel_path_has_no_parent_segment
    return unless xaccel_path.split("/").include?("..")

    errors.add(:xaccel_path, "must not contain a .. segment")
  end

  # These entries end up inside a web-server config that root parses. Only
  # literal IPv4/IPv6 addresses and CIDR blocks are accepted — never a hostname
  # (which would need resolution) and never free text.
  def ip_allowlist_entries_are_addresses
    bad = ip_allowlist_entries.reject { |entry| valid_ip_entry?(entry) }
    return if bad.empty?

    errors.add(:ip_allowlist, "has entries that are not IP addresses or CIDR blocks: #{bad.join(', ')}")
  end

  def valid_ip_entry?(entry)
    address, prefix, extra = entry.split("/", 3)
    return false if extra
    return false if prefix && !prefix.match?(/\A\d{1,3}\z/)

    IPAddr.new(entry)
    true
  rescue IPAddr::Error, ArgumentError
    false
  end
end
