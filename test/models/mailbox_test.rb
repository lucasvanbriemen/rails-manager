require "test_helper"

class MailboxTest < ActiveSupport::TestCase
  def domain(**overrides)
    MailDomain.new({ name: "lucasvanbriemen.nl", active: true, local_delivery: true,
                     catch_all: "reject" }.merge(overrides))
  end

  def build_mailbox(**overrides)
    Mailbox.new({ mail_domain: domain, local_part: "contact", active: true }.merge(overrides))
  end

  # Persisted, for the few tests that genuinely need a round trip (uniqueness,
  # encryption at rest). Built here rather than in a fixture file because
  # `fixtures :all` is global — a mail_domains.yml would appear in every other
  # test in the suite too.
  def saved_domain(name = "lucasvanbriemen.nl")
    MailDomain.create!(name: name, active: true, local_delivery: true, catch_all: "reject")
  end

  # --- SHA512-CRYPT ---------------------------------------------------------
  #
  # These are the reason the algorithm is implemented rather than delegated to
  # String#crypt: macOS's crypt(3) has no $6$ support and silently returns a
  # 13-character DES hash instead. A digest that is wrong only on the developer's
  # machine would pass every other test in this file.

  # Published vectors from Drepper's SHA-crypt specification, each re-verified
  # against this server's own glibc so they are not merely a transcription of
  # the spec agreeing with a transcription of the spec.
  SPEC_VECTORS = [
    [ "Hello world!", "saltstring", 5_000,
      "svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1" ],
    [ "Hello world!", "saltstringsaltst", 10_000,
      "OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v." ],
    [ "This is just a test", "toolongsaltstrin", 5_000,
      "lQ8jolhgVRVhY4b5pZKaysCLi0QBxGoNeKQzQ3glMhwllF7oGDZxUhx1yxdYcz/e1JSbq3y6JMxxl8audkUEm0" ],
    [ "we have a short salt string but not a short password", "short", 77_777,
      "WuQyW2YR.hBNpjjRhpYD/ifIw05xdfeEyQoMxIXbkvr0gge1a1x3yRULJ5CCaUeOxFmtlcGZelFl5CxtgfiAc0" ],
    [ "a short string", "asaltof16chars..", 123_456,
      "BtCwjqMJGx5hrJhZywWvt0RLE8uZ4oPwcelCjmw2kSYu.Ec6ycULevoBK25fs2xXgMNrCzIMVcgEJAstJeonj1" ],
    # Produced by `crypt.crypt` on server.ltvb.nl (glibc). The password
    # deliberately contains every separator this codebase rejects in a stored
    # field — a password is the one value that never reaches a config file, so
    # it must survive them intact rather than be sanitised.
    [ "p:a=s s'w\"o$r d", "0123456789./ABCD", 5_000,
      "SHgYjFJPiEP89HPVtFFKgeXj/hk2V3eLP9V/BVsaG.1yc9KoDijKvklJ1TjWuERsjYv2wEACfG1EqkKaBeycn." ],
    [ "correct horse battery staple", "abcdefghijklmnop", 5_000,
      "UY4jc6.rVibJ9tqDqiG0GMdZRHkv1j4sPRRH2eUSo3Kszltzbk30CmYcWPNRTD/KsYFHF7WTtNkAxF3dZ3zPE." ]
  ].freeze

  test "SHA512-CRYPT matches the reference implementation" do
    SPEC_VECTORS.each do |password, salt, rounds, expected|
      assert_equal expected, Mailbox::Sha512Crypt.hash(password, salt, rounds),
                   "wrong hash for #{password.inspect} with salt #{salt.inspect} at #{rounds} rounds"
    end
  end

  test "crypt spells the default round count the way glibc does" do
    digest = Mailbox::Sha512Crypt.crypt("Hello world!", salt: "saltstring")

    # No "rounds=" segment at 5000, or a `doveadm pw` comparison looks like a
    # mismatch to anyone checking a digest by hand.
    assert_equal "$6$saltstring$#{SPEC_VECTORS[0][3]}", digest
    assert_match(/\A\$6\$rounds=10000\$/, Mailbox::Sha512Crypt.crypt("x", salt: "s", rounds: 10_000))
  end

  test "a generated digest round-trips and rejects a near-miss password" do
    digest = Mailbox::Sha512Crypt.crypt("hunter2")

    assert_equal digest, Mailbox::Sha512Crypt.rehash("hunter2", digest)
    assert_not_equal digest, Mailbox::Sha512Crypt.rehash("hunter3", digest)
  end

  test "rehash fails closed on a digest that is not SHA512-CRYPT" do
    # "WXuMaSVnzYM" is what macOS's crypt(3) returns for a "$6$" salt — a DES
    # hash. If one ever reached the column, authenticate must refuse rather
    # than compare against it.
    [ "$1$abc$xyz", "WXuMaSVnzYM", "", nil, "$6$salt$tooshort" ].each do |digest|
      assert_nil Mailbox::Sha512Crypt.rehash("hunter2", digest), "accepted #{digest.inspect}"
    end
  end

  test "salts are random and use only the crypt alphabet" do
    salts = Array.new(20) { Mailbox::Sha512Crypt.random_salt }

    assert_equal 20, salts.uniq.size
    salts.each do |salt|
      assert_equal 16, salt.length
      assert_match(%r{\A[A-Za-z0-9./]{16}\z}, salt)
    end
  end

  # --- credentials ----------------------------------------------------------

  test "plaintext is never persisted and there is no reader for it" do
    mailbox = build_mailbox
    mailbox.password = "hunter2"

    assert_not mailbox.respond_to?(:password), "a password reader would recreate Plesk's problem"
    assert_not_includes mailbox.attributes.values.map(&:to_s), "hunter2"
    assert_not_includes mailbox.password_digest, "hunter2"
  end

  test "assigning a password stores a SHA512-CRYPT digest and stamps the time" do
    mailbox = build_mailbox
    mailbox.password = "hunter2"

    assert_match MailConfig::DIGEST_FORMAT, mailbox.password_digest
    assert_not_nil mailbox.password_set_at
  end

  test "two mailboxes given the same password get different digests" do
    a = build_mailbox
    b = build_mailbox(local_part: "admin")
    a.password = "13November.2006"
    b.password = "13November.2006"

    # Six of the nine real mailboxes share one password today. A per-mailbox
    # salt is what stops the rendered file advertising that fact.
    assert_not_equal a.password_digest, b.password_digest
  end

  test "authenticate accepts the password and rejects everything else" do
    mailbox = build_mailbox
    mailbox.password = "hunter2"

    assert mailbox.authenticate("hunter2")
    assert_not mailbox.authenticate("hunter3")
    assert_not mailbox.authenticate("")
    assert_not mailbox.authenticate(nil)
    # Presenting the digest itself must not authenticate.
    assert_not mailbox.authenticate(mailbox.password_digest)
  end

  test "a mailbox with no digest cannot authenticate at all" do
    mailbox = build_mailbox(password_digest: nil)

    assert mailbox.password_reset_required?
    assert_not mailbox.credentialed?
    assert_not mailbox.authenticate("")
    assert_not mailbox.authenticate("13November.2006")
  end

  test "clearing the password clears the digest rather than hashing an empty string" do
    mailbox = build_mailbox
    mailbox.password = "hunter2"
    mailbox.password = nil

    assert_nil mailbox.password_digest
    assert_nil mailbox.password_set_at
  end

  test "reset_password! returns the plaintext once and saves only the digest" do
    mailbox = saved_domain.mailboxes.create!(local_part: "resettest")
    assert_not mailbox.credentialed?

    plaintext = mailbox.reset_password!

    assert_equal Mailbox::PASSWORD_LENGTH, plaintext.length
    assert mailbox.reload.credentialed?
    assert mailbox.authenticate(plaintext)
    assert_match MailConfig::DIGEST_FORMAT, mailbox.password_digest
  end

  test "generated passwords are unique and free of ambiguous characters" do
    passwords = Array.new(25) { Mailbox.generate_password }

    assert_equal 25, passwords.uniq.size
    # No 0/O or 1/l/I: these get read aloud and copied off a screen.
    passwords.each { |password| assert_no_match(/[0O1lI]/, password) }
  end

  test "the digest column is encrypted at rest" do
    mailbox = saved_domain.mailboxes.create!(local_part: "encryptiontest")
    mailbox.reset_password!

    raw = Mailbox.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([ "SELECT password_digest FROM mailboxes WHERE id = ?", mailbox.id ])
    )

    assert_not_nil raw
    assert_not_equal mailbox.password_digest, raw
    assert_not raw.start_with?("$6$"), "the digest is sitting in the column in the clear"
  end

  # --- injection ------------------------------------------------------------
  #
  # A Dovecot passwd-file line is colon-separated, so ":" does not corrupt one
  # field — it shifts every field after it, and two positions along is the uid.
  # A Postfix map line is whitespace-separated. Neither is a newline.

  INJECTIONS = [
    "evil:0:0::/root:/bin/sh",
    "evil:x",
    "evil bad",
    "evil\tbad",
    "evil\nadmin@lucasvanbriemen.nl",
    "evil\r\nadmin",
    "evil=x",
    "evil,other@elsewhere.test",
    "evil#comment",
    "evil@other.test",
    "evil$1",
    "evil'quote",
    'evil"quote',
    "evil\\escape",
    ".evil",
    "evil.",
    "-evil",
    # A homoglyph reads as a legitimate local part in a diff but is not one.
    "evіl"
  ].freeze

  test "a local part that could shift a passwd-file field is rejected" do
    INJECTIONS.each do |value|
      mailbox = build_mailbox(local_part: value)

      assert_not mailbox.valid?, "accepted local part #{value.inspect}"
      assert mailbox.errors[:local_part].any?, "no error on :local_part for #{value.inspect}"
    end
  end

  test "a local part containing + is rejected because Postfix would never match it" do
    # main.cf sets `recipient_delimiter = +`, so Postfix strips from the first
    # "+" before consulting the map — a mailbox named "a+b" is unaddressable.
    assert_not build_mailbox(local_part: "a+b").valid?
  end

  test "a local part longer than RFC 5321 allows is rejected" do
    assert_not build_mailbox(local_part: "a" * 65).valid?
    assert build_mailbox(local_part: "a" * 64).valid?
  end

  test "the local parts that actually exist on this server are all accepted" do
    %w[ntfy admin contact development development2 emailcient info postmaster].each do |local_part|
      mailbox = build_mailbox(local_part: local_part)

      assert mailbox.valid?, "#{local_part}: #{mailbox.errors.full_messages.to_sentence}"
    end
  end

  test "local parts are normalised, not silently accepted in mixed case" do
    assert_equal "contact", build_mailbox(local_part: "  Contact  ").tap(&:valid?).local_part
  end

  test "a digest that is not SHA512-CRYPT is refused on the way in" do
    # Rejected while someone is looking at the record, not at render time when
    # the whole passwd-file would fail to write and every account loses auth.
    [ "not-a-digest", "$1$abc$xyz", "$6$salt$short",
      "$6$sa:lt$#{'a' * 86}", "$6$salt$#{'a' * 85}", "WXuMaSVnzYM" ].each do |digest|
      mailbox = build_mailbox(password_digest: digest)

      assert_not mailbox.valid?, "accepted digest #{digest.inspect}"
    end
  end

  test "a well-formed digest with an explicit round count is accepted" do
    assert build_mailbox(password_digest: Mailbox::Sha512Crypt.crypt("x", rounds: 10_000)).valid?
  end

  # --- paths ----------------------------------------------------------------

  test "the Maildir layout matches what is already on disk" do
    mailbox = build_mailbox(local_part: "contact")

    # 143 MB of real mail lives at these exact paths and must not move.
    assert_equal "/var/qmail/mailnames/lucasvanbriemen.nl/contact", mailbox.home_path
    assert_equal "/var/qmail/mailnames/lucasvanbriemen.nl/contact/Maildir", mailbox.maildir_path
    assert_equal "contact@lucasvanbriemen.nl", mailbox.address
  end

  test "the relative maildir keeps the trailing slash Postfix needs" do
    # Without it Postfix appends to a FILE called Maildir instead of delivering
    # into a maildir, which corrupts delivery and hides the mail from Dovecot.
    assert_equal "lucasvanbriemen.nl/contact/Maildir/", build_mailbox.relative_maildir
  end

  test "paths and ids are derived, never stored" do
    # A stored path is a path someone can point at another mailbox; a stored
    # uid is a per-row privilege decision.
    %w[maildir_path home_path uid gid].each do |column|
      assert_not_includes Mailbox.column_names, column
    end
  end

  # --- delivery vs authentication ------------------------------------------

  test "a mailbox on a domain whose MX is elsewhere can still be read" do
    # info@mos-safeguards.com: MX is mx.transip.email, so no NEW mail arrives
    # here, but the existing Maildir must stay reachable over IMAP.
    elsewhere = domain(name: "mos-safeguards.com", local_delivery: false)
    mailbox = build_mailbox(mail_domain: elsewhere, local_part: "info")
    mailbox.password = "hunter2"

    assert_not mailbox.receives_mail?
    assert mailbox.can_authenticate?
  end

  test "an inactive domain stops both delivery and authentication" do
    mailbox = build_mailbox(mail_domain: domain(active: false))
    mailbox.password = "hunter2"

    assert_not mailbox.receives_mail?
    assert_not mailbox.can_authenticate?
  end

  test "an inactive mailbox neither receives nor authenticates" do
    mailbox = build_mailbox(active: false)
    mailbox.password = "hunter2"

    assert_not mailbox.receives_mail?
    assert_not mailbox.can_authenticate?
  end

  # --- quota ----------------------------------------------------------------

  test "a blank quota means unlimited and a non-positive one is rejected" do
    # Plesk recorded -1 (unlimited) for all nine, and contact@lucasvanbriemen.nl
    # is already at ~114 MB — inventing a limit would start bouncing its mail.
    assert build_mailbox(quota_bytes: nil).unlimited_quota?
    assert build_mailbox(quota_bytes: 5_000_000_000).valid?
    assert_not build_mailbox(quota_bytes: 0).valid?
    assert_not build_mailbox(quota_bytes: -1).valid?
  end

  # --- uniqueness -----------------------------------------------------------

  test "one address cannot be claimed twice" do
    saved = saved_domain
    saved.mailboxes.create!(local_part: "contact")

    # Two rows would render two lines into one map, and postmap and Dovecot
    # both silently take whichever came first.
    assert_not Mailbox.new(mail_domain: saved, local_part: "contact").valid?
  end

  test "the same local part on two domains is a different mailbox" do
    saved_domain.mailboxes.create!(local_part: "contact")
    other = saved_domain("voordezorgmanagement.nl")

    # contact@lucasvanbriemen.nl and contact@voordezorgmanagement.nl both exist.
    assert Mailbox.new(mail_domain: other, local_part: "contact").valid?
  end

  # --- shadowing ------------------------------------------------------------
  #
  # The guard has to exist on BOTH sides. MailConfig#render validates every row
  # set before it renders any file, so an alias/mailbox collision created from
  # the mailbox side makes all six files unrenderable — vmailbox and the
  # passwd-file included, neither of which involves aliases.

  test "a mailbox cannot be created over an existing alias" do
    saved = saved_domain
    saved.mail_aliases.create!(local_part: "sales", destinations: [ "contact@lucasvanbriemen.nl" ])
    mailbox = Mailbox.new(mail_domain: saved, local_part: "sales")

    assert_not mailbox.valid?, "a mailbox shadowed by an alias must be refused on the way in"
    assert_match(/already an alias/, mailbox.errors[:local_part].to_sentence)
  end

  test "a disabled alias still blocks a mailbox, because enabling it later would break rendering" do
    saved = saved_domain
    saved.mail_aliases.create!(local_part: "sales", enabled: false,
                               destinations: [ "contact@lucasvanbriemen.nl" ])

    assert_not Mailbox.new(mail_domain: saved, local_part: "sales").valid?
  end

  test "an alias on another domain does not block the mailbox" do
    saved_domain.mail_aliases.create!(local_part: "sales", destinations: [ "contact@ltvb.nl" ])
    other = saved_domain("voordezorgmanagement.nl")

    assert Mailbox.new(mail_domain: other, local_part: "sales").valid?
  end

  test "neither side of a shadowing pair can be saved, and rendering stays possible" do
    saved = saved_domain
    saved.mailboxes.create!(local_part: "contact")
    shadow = MailAlias.new(mail_domain: saved, local_part: "contact", destinations: [ "x@ltvb.nl" ])

    assert_not shadow.valid?, "the alias side was already guarded and must stay guarded"
    assert MailConfig.new.render_all.present?, "a legal database must always render"
  end
end
