# Mail is the only genuinely irreversible part of the Plesk exit. Everything
# else Plesk owns has a plaintext source somewhere: vhosts can be re-rendered,
# crontabs can be read back, databases can be dumped. The mail maps cannot —
# /var/spool/postfix/plesk/{vmailbox,virtual,virtual_domains} are Berkeley DB
# files that Plesk generates from the psa database, and once Plesk is gone there
# is no `postmap -s` source left to regenerate them from. This table set IS that
# source, in plaintext, from now on.
#
# Three things are deliberately NOT carried over from the export:
#
#   1. Passwords. All nine mailboxes land here with a NULL digest, which means
#      "cannot authenticate until reset". Six of the nine share one identical
#      password today and one was used to relay ~12k phishing messages, so
#      copying the credentials across would import the incident along with the
#      accounts. Plesk stored them recoverably (its auth database prints them in
#      plaintext); this table stores only a SHA512-CRYPT digest, encrypted.
#
#   2. The 44 virtual_alias entries. Every one of them is Plesk plumbing —
#      drweb@, kluser@, anonymous@, mailer-daemon@ pointed at
#      localhost.localdomain, plus one identity entry per mailbox that exists
#      only to make Plesk's own transport fire. None of it means anything
#      without Plesk, so mail_aliases starts empty rather than importing the
#      shape we are leaving.
#
#   3. local_delivery for the three domains whose MX is elsewhere. See below —
#      this is a live bug being fixed, not a faithful transcription.
class CreateMailTables < ActiveRecord::Migration[8.0]
  # Read off `postfix-vmailbox.txt` and `psa-mailboxes.tsv`. 143 MB of real mail
  # lives under this root and must not move; the migration records where each
  # Maildir already is rather than deriving a new layout.
  MAILDIR_ROOT = "/var/qmail/mailnames".freeze

  def change
    create_table :mail_domains do |t|
      t.string  :name, null: false

      # Off retires a domain without losing its mailboxes, their quotas or their
      # Maildir paths.
      t.boolean :active, null: false, default: true

      # THE field this table exists for. Postfix rejects mail for a domain
      # listed in virtual_mailbox_domains that has no matching mailbox — and
      # accepting a domain means claiming to be its final destination, which is
      # only true if the MX points here.
      #
      # Six domains are in virtual_mailbox_domains today but only three have MX
      # pointing at this server. djtim.eu and rijschool-mos.nl point at
      # smtp.rzone.de and mos-safeguards.com at mx.transip.email, so right now
      # this server accepts a message for one of those three, finds no local
      # mailbox, and BOUNCES it — instead of relaying it to the MX that actually
      # holds the mail. Turning local_delivery off removes the domain from
      # virtual_mailbox_domains, at which point Postfix does the ordinary MX
      # lookup and the mail arrives.
      t.boolean :local_delivery, null: false, default: true

      # NULL means this domain does not sign. Non-NULL is the selector whose key
      # lives at /etc/domainkeys/<name>/<selector>.
      t.string  :dkim_selector

      # What happens to mail for an address that does not exist here. Only the
      # two policies that render differently exist — see MailDomain.
      t.string  :catch_all, null: false, default: "reject"
      t.string  :catch_all_target

      t.text    :notes

      t.timestamps
    end

    add_index :mail_domains, :name, unique: true

    create_table :mailboxes do |t|
      t.references :mail_domain, null: false, foreign_key: true

      t.string  :local_part, null: false

      # SHA512-CRYPT ("$6$<salt>$<86 chars>"), encrypted at rest on top of that.
      # NULL means no credential: the mailbox still receives mail, but it is
      # omitted from the Dovecot passwd-file entirely, so there is no line for
      # anyone to authenticate against. Every row this migration creates starts
      # here, which is how "reset all nine" is enforced rather than remembered.
      t.text    :password_digest
      t.datetime :password_set_at

      # NULL is unlimited, which is what all nine are today (Plesk stored -1).
      t.bigint  :quota_bytes

      t.boolean :active, null: false, default: true

      t.text    :notes

      t.timestamps
    end

    # Two rows for one address would render two lines into the same map, and
    # both postmap and Dovecot silently take whichever came first.
    add_index :mailboxes, [ :mail_domain_id, :local_part ], unique: true

    create_table :mail_aliases do |t|
      t.references :mail_domain, null: false, foreign_key: true

      t.string  :local_part, null: false

      # An ARRAY of full addresses. Postfix joins them with ", " in one map
      # value, so a single free-text field would put the separator inside the
      # data — the same mistake as a command string instead of argv.
      t.json    :destinations, null: false, default: []

      t.boolean :enabled, null: false, default: true

      t.text    :notes

      t.timestamps
    end

    add_index :mail_aliases, [ :mail_domain_id, :local_part ], unique: true

    reversible { |dir| dir.up { adopt_existing_mail! } }
  end

  private

  def adopt_existing_mail!
    domain_ids = {}

    domain_rows.each do |row|
      mail_domains.insert_all([ row ], record_timestamps: true)
    end
    mail_domains.pluck(:name, :id).each { |name, id| domain_ids[name] = id }

    rows = mailbox_rows.map do |row|
      domain = row.delete(:domain)
      row.merge(mail_domain_id: domain_ids.fetch(domain))
    end
    mailboxes.insert_all(rows, record_timestamps: true)
  end

  # Defined inline rather than using the models: a migration has to keep working
  # after they change, and MailDomain's validations would reject a NULL digest
  # this migration inserts on purpose.
  def mail_domains
    @mail_domains ||= Class.new(ActiveRecord::Base) { self.table_name = "mail_domains" }
  end

  def mailboxes
    @mailboxes ||= Class.new(ActiveRecord::Base) { self.table_name = "mailboxes" }
  end

  # From postfix-virtual_domains.txt (which six domains Postfix accepts),
  # psa-domain-mail-settings.tsv (DKIM selector and whether the domain signs)
  # and psa-catchall.tsv (all six are "reject").
  #
  # local_delivery is the one column that does NOT transcribe the export. The
  # three domains whose MX is elsewhere get `false`, which is what makes this
  # server stop bouncing their mail.
  def domain_rows
    [
      { name: "ltvb.nl", local_delivery: true, dkim_selector: "default",
        notes: "MX points here. Holds ntfy@, the notification sender." },
      { name: "lucasvanbriemen.nl", local_delivery: true, dkim_selector: "default",
        notes: <<~TXT
          MX points here. Six of the nine mailboxes live on this domain.
          Plesk signed this domain with selector "lucasvanbriemen.nl", not "default" —
          the key was re-issued under "default" so all four signing domains match. The
          DNS TXT record at default._domainkey must exist before signing is re-enabled,
          or every message from this domain fails DKIM instead of being unsigned.
        TXT
      },
      { name: "voordezorgmanagement.nl", local_delivery: true, dkim_selector: "default",
        notes: "MX points here. Holds contact@." },
      { name: "mos-safeguards.com", local_delivery: false, dkim_selector: "default",
        notes: <<~TXT
          MX is mx.transip.email, NOT this server — but Postfix lists the domain in
          virtual_mailbox_domains today, so this box declares itself the final
          destination for mail it is not the destination for.
          info@mos-safeguards.com still exists here with a real Maildir, and its row is
          kept so IMAP keeps working: local_delivery gates Postfix only, never the
          Dovecot passwd-file. New mail arrives at TransIP; the history stays readable
          here.
        TXT
      },
      { name: "djtim.eu", local_delivery: false, dkim_selector: nil,
        notes: <<~TXT
          MX is smtp.rzone.de. No mailboxes here and Plesk did not sign it, so nothing
          on this server should have been accepting its mail at all — with
          local_delivery off, Postfix relays to rzone instead of bouncing.
        TXT
      },
      { name: "rijschool-mos.nl", local_delivery: false, dkim_selector: nil,
        notes: <<~TXT
          MX is smtp.rzone.de. No mailboxes here and Plesk did not sign it.
          NOTE: student.rijschool-mos.nl runs an hourly send-mail cron job. It sends
          THROUGH this server as a client; that is submission, not local delivery, and
          is unaffected by this flag.
        TXT
      }
    ].map { |row| { active: true, catch_all: "reject", catch_all_target: nil }.merge(row) }
  end

  # The nine real mailboxes, from postfix-vmailbox.txt cross-checked against
  # psa-mailboxes.tsv. Every one carries a NULL password_digest.
  #
  # Quotas are all NULL: Plesk recorded -1 (unlimited) for all nine, and
  # contact@lucasvanbriemen.nl is already at 114 MB, so inventing a limit here
  # would start bouncing its mail on the day of the cutover.
  def mailbox_rows
    shared = <<~TXT
      Password NOT carried over: this account was one of six sharing the single
      password "13November.2006", which Plesk stored recoverably. Must be reset before
      it can authenticate.
    TXT

    [
      { domain: "ltvb.nl", local_part: "ntfy", notes: shared },
      { domain: "lucasvanbriemen.nl", local_part: "admin", notes: shared },
      { domain: "lucasvanbriemen.nl", local_part: "development", notes: shared },
      { domain: "lucasvanbriemen.nl", local_part: "development2", notes: shared },
      { domain: "lucasvanbriemen.nl", local_part: "emailcient", notes: shared },
      { domain: "lucasvanbriemen.nl", local_part: "postmaster",
        notes: "#{shared}\nRFC 2142 postmaster for lucasvanbriemen.nl. 6.1 MB on disk." },
      { domain: "lucasvanbriemen.nl", local_part: "contact",
        notes: <<~TXT
          The only mailbox with a password of its own rather than the shared one, which
          is consistent with it having been reset after the relay incident. Reset anyway
          — Plesk could print it in plaintext, so it is not a secret.
          Largest mailbox on the server at ~114 MB; do not set a quota below that.
        TXT
      },
      { domain: "mos-safeguards.com", local_part: "info",
        notes: <<~TXT
          Password "missoe(2025)", not carried over.
          Its domain has local_delivery: false (MX is TransIP), so this mailbox receives
          no NEW mail through this server. The row exists so the existing Maildir stays
          reachable over IMAP.
        TXT
      },
      { domain: "voordezorgmanagement.nl", local_part: "contact",
        notes: "Password \"13November.\", not carried over." }
    ].map do |row|
      { active: true, password_digest: nil, password_set_at: nil, quota_bytes: nil }.merge(row)
    end
  end
end
