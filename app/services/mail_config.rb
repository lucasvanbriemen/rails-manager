require "erb"

# Renders the mail configuration that replaces Plesk's, from the manager's own
# tables, as PLAINTEXT.
#
# Plaintext is the whole point. Plesk's three maps live in
# /var/spool/postfix/plesk/ as Berkeley DB files generated from the psa
# database; there is no `.txt` beside them, so when Plesk is removed the only
# copy of who receives mail here is a binary blob no tool left on the box can
# regenerate. Everything this class emits is a text file that is itself the
# source of truth — `postmap` derives the .db from it, never the other way
# round.
#
# This is a trust boundary in exactly the sense NginxConfig and SystemdUnit are,
# but the separator is different and that difference is the trap. A Dovecot
# passwd-file line is
#
#   user:{SHA512-CRYPT}$6$…:uid:gid:gecos:home:shell:extra
#
# so a `:` smuggled into a local part does not corrupt one field — it shifts
# every field after it, and the field two positions along is the numeric uid.
# A Postfix map line is `key<whitespace>value`, so a space does the same there.
# Neither is a newline, which is the character everyone remembers to check.
# `safe!` therefore rejects `:`, `=`, `,`, whitespace and `#` in every field,
# not just newline, and each accessor below is an allow-list on top of that.
class MailConfig
  # Raised instead of rendering. A partially-rendered map is worse than none: a
  # truncated vmailbox silently stops delivering to every address below the
  # truncation point, and nothing bounces — Postfix simply rejects them as
  # unknown users.
  class UnsafeValue < StandardError; end

  # Where root reads these from, and the reason it is not this checkout. Same
  # argument as NginxConfig::TEMPLATE_DIR: the checkout is owned by uid 10006,
  # the uid eight internet-facing apps share, so a template read from Rails.root
  # means an RCE in any one of them rewrites a file that decides who may
  # authenticate as whom.
  TEMPLATE_DIR     = Pathname.new("/etc/ltvb/agent/templates/mail")
  # Development and test only; a production box missing TEMPLATE_DIR raises
  # rather than silently reaching into the checkout.
  DEV_TEMPLATE_DIR = Rails.root.join("deploy/templates/mail")

  # 143 MB of real mail already lives here and must not move. Postfix is told
  # this as `virtual_mailbox_base` and the vmailbox map holds paths RELATIVE to
  # it; Dovecot is told the absolute home per mailbox.
  MAILDIR_ROOT = "/var/qmail/mailnames".freeze

  # popuser:popuser. Constants, never columns and never template parameters: a
  # per-mailbox uid is a per-mailbox privilege decision, and the only correct
  # answer on this box is the one the 143 MB of existing Maildirs is already
  # owned by. Making it a parameter would mean a row in a table could choose
  # which uid Dovecot reads and writes files as.
  VMAIL_UID = 30
  VMAIL_GID = 31

  DKIM_ROOT = "/etc/domainkeys".freeze

  # The scheme prefix every password field carries, and the field written for a
  # mailbox that has no credential yet.
  #
  # NO_PASSWORD is not decoration and it is not an empty field. The passwd-file
  # answers TWO different questions — "may this password log in" (passdb) and
  # "does this mailbox exist, and where is its Maildir" (userdb) — and
  # `virtual_transport = lmtp:` makes every delivery depend on the second one.
  # Dovecot LMTP answers a userdb miss with a permanent "User doesn't exist"
  # 5.1.1, and by then Postfix has already accepted the message because the
  # address is in vmailbox: the result is a BOUNCE, not a queue and not a login
  # failure. That is the same failure mode the main.cf fragment warns about for
  # plesk_virtual, so omitting a line here for a mailbox that vmailbox lists
  # would reintroduce it — and straight out of the migration ALL NINE mailboxes
  # have a NULL digest, so a digest filter would bounce every existing account
  # on cutover day.
  #
  # "*" cannot be produced by crypt(3), so no password can ever match it and
  # authentication fails closed. An EMPTY field is deliberately not used: empty
  # is a credential question ("what does Dovecot do with it?", which depends on
  # `nopassword`), and "*" is not.
  PASSWORD_SCHEME = "{SHA512-CRYPT}".freeze
  NO_PASSWORD     = "#{PASSWORD_SCHEME}*".freeze

  # Postfix reads the .db that `postmap` derives from each of these; Dovecot
  # reads the passwd-file directly. The passwd-file is 0640 root:dovecot because
  # it holds password digests — the maps beside it are world-readable because
  # they are just addresses, and making them 0600 would only hide them from the
  # operator.
  FILES = {
    "virtual_domains" => {
      path: "/etc/postfix/ltvb/virtual_domains", template: "virtual_domains.erb",
      mode: 0o644, postmap: true
    },
    "vmailbox" => {
      path: "/etc/postfix/ltvb/vmailbox", template: "vmailbox.erb",
      mode: 0o644, postmap: true
    },
    "virtual" => {
      path: "/etc/postfix/ltvb/virtual", template: "virtual.erb",
      mode: 0o644, postmap: true
    },
    "dovecot_passwd" => {
      path: "/etc/dovecot/ltvb/passwd", template: "dovecot_passwd.erb",
      mode: 0o640, postmap: false
    },
    "dovecot_auth" => {
      path: "/etc/dovecot/ltvb/auth.conf", template: "dovecot_auth.conf.erb",
      mode: 0o644, postmap: false
    },
    "main_cf" => {
      path: "/etc/postfix/ltvb/main.cf.fragment", template: "main_cf_fragment.cf.erb",
      mode: 0o644, postmap: false
    }
  }.freeze

  # --- patterns -------------------------------------------------------------
  # Allow-lists: each says what a value may look like, never what it may not, so
  # a character nobody thought of is rejected by default. `safe!` is the shared
  # deny-list underneath, redundant on purpose, because it produces the error
  # message that names the offending character.

  # RFC 5321 caps a local part at 64 octets. `+` is excluded even though it is a
  # legal local-part character: main.cf sets `recipient_delimiter = +`, so
  # Postfix strips everything from the first `+` before consulting the map, and
  # a mailbox actually named "a+b" could never be addressed. Storing one would
  # produce a map line that silently never matches.
  LOCAL_PART      = /\A[a-z0-9]([a-z0-9._-]*[a-z0-9])?\z/
  MAX_LOCAL_PART  = 64
  DOMAIN_FORMAT   = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/
  MAX_DOMAIN      = 253
  # SHA512-CRYPT, with the optional non-default round count glibc and Dovecot
  # both accept. The 86-character tail is fixed-width for SHA-512.
  DIGEST_FORMAT   = %r{\A\$6\$(rounds=\d{4,9}\$)?[A-Za-z0-9./]{1,16}\$[A-Za-z0-9./]{86}\z}
  DKIM_SELECTOR   = /\A[a-z0-9]([a-z0-9._-]*[a-z0-9])?\z/
  MAX_VALUE_BYTES = 320

  # Everything that would shift a field, start a comment, split a token or be
  # invisible in a diff. `:` is the Dovecot field separator, whitespace is the
  # Postfix one, `,` separates Postfix map values, `#` opens a comment in both
  # formats, and `=` opens a Dovecot extra field. `$` would be expanded by
  # Postfix in main.cf. The rest can never appear in a legitimate address.
  FORBIDDEN = /[\s:=,#'"\\$`|;{}<>()\[\]]|[\p{Cntrl}]/

  class << self
    def render(name) = new.render(name)

    # Every file, rendered together. Callers install them as a set: a vmailbox
    # naming a mailbox the passwd-file does not is a mailbox that receives mail
    # nobody can read, and vice versa.
    def render_all = new.render_all

    def file(name) = FILES.fetch(name)

    # ---- validators -----------------------------------------------------
    # Shared with the models, which call them from `validate` blocks, so a value
    # is rejected while a human is still looking at the form rather than at
    # render time when nobody is.

    def safe!(value, field:)
      string = value.to_s
      raise UnsafeValue, "#{field} is blank" if string.empty?
      raise UnsafeValue, "#{field} is longer than #{MAX_VALUE_BYTES} bytes" if string.bytesize > MAX_VALUE_BYTES
      raise UnsafeValue, "#{field} is not ASCII: #{string.inspect}" unless string.ascii_only?

      bad = string[FORBIDDEN]
      if bad
        raise UnsafeValue,
              "#{field} contains #{bad.inspect}, which would shift the fields of a Dovecot " \
              "passwd-file line or split a Postfix map line"
      end

      string
    end

    def safe_local_part!(value, field: "local part")
      local = safe!(value, field: field)
      if local.bytesize > MAX_LOCAL_PART
        raise UnsafeValue, "#{field} #{local.inspect} is longer than #{MAX_LOCAL_PART} octets"
      end
      unless local.match?(LOCAL_PART)
        raise UnsafeValue,
              "#{field} #{local.inspect} is not a plain lowercase local part " \
              "(a leading/trailing dot or a `+` would never match a map line)"
      end

      local
    end

    def safe_domain!(value, field: "domain")
      domain = safe!(value, field: field)
      unless domain.match?(DOMAIN_FORMAT) && domain.bytesize <= MAX_DOMAIN
        raise UnsafeValue, "#{field} #{domain.inspect} is not a dotted hostname"
      end

      domain
    end

    # A full address, checked as its two halves rather than as one string, so
    # "a@b@c" cannot pass by looking address-shaped.
    def safe_address!(value, field: "address")
      address = safe!(value, field: field)
      local, at, domain = address.rpartition("@")
      raise UnsafeValue, "#{field} #{address.inspect} is not local@domain" if at.empty?

      "#{safe_local_part!(local, field: field)}@#{safe_domain!(domain, field: field)}"
    end

    # The digest is the one field that legitimately contains `$` and `/`, so it
    # gets a format check instead of `safe!`. It still must not contain a `:` —
    # DIGEST_FORMAT is anchored and its alphabet excludes one, so that is
    # covered by the pattern rather than by an extra pass.
    def safe_digest!(value, field: "password digest")
      digest = value.to_s
      raise UnsafeValue, "#{field} is blank" if digest.empty?
      unless digest.match?(DIGEST_FORMAT)
        raise UnsafeValue, "#{field} is not a SHA512-CRYPT digest ($6$<salt>$<86 chars>)"
      end

      digest
    end

    def safe_dkim_selector!(value, field: "DKIM selector")
      selector = safe!(value, field: field)
      raise UnsafeValue, "#{field} #{selector.inspect} is not a plain selector" unless selector.match?(DKIM_SELECTOR)

      selector
    end

    # Dovecot's quota value is rendered as `userdb_quota_storage_size=<n>`, so
    # anything that is not a positive integer would either be ignored silently
    # or, worse, parsed as a smaller number than intended.
    def safe_quota!(value, field: "quota")
      bytes = begin
        Integer(value.to_s, 10)
      rescue TypeError, ArgumentError
        raise UnsafeValue, "#{field} #{value.inspect} is not a whole number of bytes"
      end
      raise UnsafeValue, "#{field} must be positive, or blank for unlimited" unless bytes.positive?

      bytes
    end

    # ---- template location ------------------------------------------------
    # Identical policy to NginxConfig, re-resolved per render rather than
    # memoised so a reinstalled template does not need a Passenger restart and a
    # directory that became writable does not keep passing a boot-time check.

    def template_path(name)
      dir = installed_template_dir
      return trusted_template!(dir.join(name)) if dir

      unless Rails.env.development? || Rails.env.test?
        raise UnsafeValue, "#{TEMPLATE_DIR} is not installed; refusing to render templates from #{Rails.root} " \
                           "(see the install step in deploy/agent/README.md)"
      end

      DEV_TEMPLATE_DIR.join(name)
    end

    def installed_template_dir
      stat = File.lstat(TEMPLATE_DIR)
      unless stat.directory? && stat.uid.zero? && (stat.mode & 0o022).zero?
        raise UnsafeValue, "#{TEMPLATE_DIR} must be a root-owned directory that nobody else can write"
      end

      TEMPLATE_DIR
    rescue Errno::ENOENT
      nil
    end

    # lstat, not stat: the symlink itself is what an attacker gets to plant, and
    # File::Stat#file? is false for one.
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

  # Collections are injectable so a test can render a record that was never
  # allowed to be saved. They default to the whole table because these files
  # describe the server, not one app: there is exactly one vmailbox map, and
  # rendering it from a subset would delete every address outside that subset.
  def initialize(domains: nil, mailboxes: nil, mail_aliases: nil)
    @domains      = domains
    @mailboxes    = mailboxes
    @mail_aliases = mail_aliases
  end

  def domains      = @domains      ||= MailDomain.ordered.to_a
  def mailboxes    = @mailboxes    ||= Mailbox.includes(:mail_domain).ordered.to_a
  def mail_aliases = @mail_aliases ||= MailAlias.includes(:mail_domain).ordered.to_a

  def render(name)
    config = self.class.file(name)
    validate!
    erb(self.class.template_path(config[:template]))
  end

  def render_all
    FILES.keys.index_with { |name| render(name) }
  end

  # Every row set is built and checked before ANY file is rendered, so one bad
  # record fails all six rather than producing five good files and one that
  # quietly omits a line.
  def validate!
    domain_rows
    mailbox_rows
    alias_rows
    passwd_rows
    true
  end

  # --- rows -----------------------------------------------------------------
  # Each returns validated, ready-to-print values. The templates do no
  # validation and no lookups; they lay out what is already safe.

  # Only these domains go into virtual_mailbox_domains. A domain listed here is
  # a domain this server claims to be the final destination for, which is a
  # claim about DNS, not about whether we happen to hold a Maildir for it.
  def domain_rows
    @domain_rows ||= domains.select { |d| d.active? && d.local_delivery? }.map do |domain|
      { name: self.class.safe_domain!(domain.name) }
    end
  end

  def mailbox_rows
    @mailbox_rows ||= begin
      rows = deliverable_mailboxes.map do |mailbox|
        domain = self.class.safe_domain!(mailbox.mail_domain.name)
        local  = self.class.safe_local_part!(mailbox.local_part)
        {
          address: "#{local}@#{domain}",
          # Relative to virtual_mailbox_base, and the TRAILING SLASH is load
          # bearing: it is the only thing telling Postfix this is a maildir and
          # not an mbox. Without it Postfix appends messages to a FILE named
          # Maildir, which both corrupts delivery and is unreadable by Dovecot.
          maildir: "#{domain}/#{local}/Maildir/"
        }
      end
      no_duplicates!(rows.map { |r| r[:address] }, "mailbox address")
      rows
    end
  end

  # The shadow check runs over the EXPLICIT aliases only, before the catch-all
  # rows are added: the identity rows a forwarding domain generates are sources
  # that are also mailbox addresses on purpose (see catch_all_rows), and they
  # are the guard against diversion rather than an instance of it.
  def alias_rows
    @alias_rows ||= begin
      explicit = enabled_alias_rows
      shadowed = explicit.map { |r| r[:source] } & mailbox_rows.map { |r| r[:address] }
      if shadowed.any?
        raise UnsafeValue,
              "#{shadowed.join(', ')} is both a mailbox and an alias source. Postfix applies " \
              "virtual_alias_maps BEFORE virtual_mailbox_maps, so the alias would silently " \
              "divert the mailbox's mail and nothing would be delivered to it."
      end

      rows = catch_all_rows + explicit
      no_duplicates!(rows.map { |r| r[:source] }, "alias source")
      rows
    end
  end

  # Deliberately NOT filtered by local_delivery. mos-safeguards.com's MX is
  # TransIP, so Postfix must not accept new mail for it — but info@ still has a
  # real Maildir here and its owner still needs IMAP to read it. local_delivery
  # gates Postfix; the passwd-file follows the mailboxes.
  #
  # And deliberately NOT filtered by password_digest either: this file is the
  # USERDB as well as the passdb, and every mailbox vmailbox names must be
  # resolvable here or LMTP bounces its mail. A mailbox with no credential gets
  # a line with NO_PASSWORD in the password field — see that constant for why
  # the alternative (no line) is a bounce and why the other alternative (an
  # empty field) is a credential question.
  def passwd_rows
    @passwd_rows ||= begin
      rows = mailboxes.select { |m| m.active? && m.mail_domain.active? }.map do |mailbox|
        domain = self.class.safe_domain!(mailbox.mail_domain.name)
        local  = self.class.safe_local_part!(mailbox.local_part)
        {
          address:      "#{local}@#{domain}",
          # The whole field, scheme included, so the template lays out what is
          # already safe rather than assembling a credential.
          password:     password_field(mailbox),
          credentialed: mailbox.password_digest.present?,
          home:         "#{MAILDIR_ROOT}/#{domain}/#{local}",
          extra:        quota_extra(mailbox)
        }
      end
      no_duplicates!(rows.map { |r| r[:address] }, "passwd-file user")
      rows
    end
  end

  # The accounts that can receive mail but cannot yet log in. Listed as comments
  # at the top of the file, because "these eight cannot authenticate" is the
  # state the migration starts in and it must not be something anyone has to
  # remember.
  def credential_less_rows = passwd_rows.reject { |row| row[:credentialed] }

  def signing_domains
    domains.select { |d| d.active? && d.dkim_selector.present? }.map do |domain|
      name     = self.class.safe_domain!(domain.name)
      selector = self.class.safe_dkim_selector!(domain.dkim_selector)
      { name: name, selector: selector, key_path: "#{DKIM_ROOT}/#{name}/#{selector}" }
    end
  end

  # --- template helpers -----------------------------------------------------

  def path_for(name) = FILES.fetch(name)[:path]

  def generated_header(what)
    "# #{what}\n" \
    "# Generated by ltvb-apps (MailConfig) — do not edit by hand; edit the mail\n" \
    "# tables and re-render. THIS FILE IS THE SOURCE OF TRUTH, not the .db beside it.\n"
  end

  private

  def deliverable_mailboxes
    mailboxes.select { |m| m.active? && m.mail_domain.active? && m.mail_domain.local_delivery? }
  end

  def enabled_alias_rows
    mail_aliases.select { |a| a.enabled? && a.mail_domain.active? && a.mail_domain.local_delivery? }.map do |entry|
      domain       = self.class.safe_domain!(entry.mail_domain.name)
      local        = self.class.safe_local_part!(entry.local_part)
      destinations = Array(entry.destinations).map { |d| self.class.safe_address!(d, field: "alias destination") }
      raise UnsafeValue, "alias #{local}@#{domain} has no destination" if destinations.empty?

      { source: "#{local}@#{domain}", destinations: destinations }
    end
  end

  # `@domain` as a map key is Postfix's catch-all. "reject" renders nothing at
  # all — the absence of a key is what makes Postfix reject an unknown
  # recipient, so there is no line to write.
  #
  # A forwarding domain renders one identity row per mailbox BEFORE its wildcard,
  # and those rows are load bearing. virtual(5)'s search order is `user@domain`,
  # then `user`, then `@domain` LAST — so a bare wildcard is consulted for every
  # recipient at the domain that has no more specific key, INCLUDING the
  # domain's own mailboxes, and virtual_alias_maps is applied before
  # virtual_mailbox_maps. Turning catch-all forwarding on would otherwise divert
  # every mailbox on the domain (contact@lucasvanbriemen.nl is 114 MB) to the
  # forward target, with nothing in the rendered config looking wrong.
  # `local@domain -> local@domain` is a more specific key that rewrites the
  # address to itself, so vmailbox then delivers it. Plesk's map carries exactly
  # one of these per mailbox for this reason, not for its own transport.
  def catch_all_rows
    domains.select { |d| d.active? && d.local_delivery? && d.forwards_catch_all? }.flat_map do |domain|
      name   = self.class.safe_domain!(domain.name)
      target = self.class.safe_address!(domain.catch_all_target, field: "catch-all target")
      guards = mailbox_rows.select { |row| row[:address].end_with?("@#{name}") }
                           .map { |row| { source: row[:address], destinations: [ row[:address] ] } }

      guards + [ { source: "@#{name}", destinations: [ target ] } ]
    end
  end

  def password_field(mailbox)
    return NO_PASSWORD if mailbox.password_digest.blank?

    "#{PASSWORD_SCHEME}#{self.class.safe_digest!(mailbox.password_digest)}"
  end

  # Dovecot 2.4 renamed the quota userdb field; `quota_storage_size` is what the
  # Plesk userdb SQL on this box already returns, so it is what this server's
  # Dovecot is known to understand.
  def quota_extra(mailbox)
    return [] if mailbox.quota_bytes.blank?

    [ "userdb_quota_storage_size=#{self.class.safe_quota!(mailbox.quota_bytes)}" ]
  end

  def no_duplicates!(keys, label)
    dupes = keys.tally.select { |_, count| count > 1 }.keys
    return if dupes.empty?

    raise UnsafeValue,
          "duplicate #{label}: #{dupes.join(', ')}. postmap and Dovecot both take whichever " \
          "line came first, so the other one would be silently dead."
  end

  def erb(path)
    ERB.new(File.read(path), trim_mode: "-").result(template_binding)
  end

  # A binding with no locals of its own, so a template can only reach the
  # methods above.
  def template_binding = binding
end
