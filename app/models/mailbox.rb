require "digest"
require "securerandom"

# One mail account: an address, a Maildir, and a password digest.
#
# The credential rules here are the whole reason this table exists rather than a
# script that copies Plesk's. Plesk kept passwords RECOVERABLY — `plesk bin
# mail --info` prints all nine in plaintext, which is how we know that six of
# them share the single string "13November.2006" and that one of those six was
# used to relay roughly 12k phishing messages. It kept them recoverably because
# it offered CRAM-MD5 and APOP, and those mechanisms require the server to hold
# something plaintext-equivalent.
#
# So: this model stores only a SHA512-CRYPT digest, encrypted at rest on top of
# that, and there is deliberately no way to read a password back out. Plaintext
# is generated here, returned to the caller once, and never assigned to an
# attribute. The cost is that CRAM-MD5/APOP cannot be offered any more, which is
# a feature — see the auth_mechanisms line in the Dovecot fragment.
class Mailbox < ApplicationRecord
  # SHA-512 crypt, implemented rather than delegated to String#crypt.
  #
  # String#crypt calls the platform crypt(3), and macOS's does not implement
  # $6$ at all — it silently falls back to DES and returns a 13-character
  # string. "Silently returns a different, catastrophically weaker hash on the
  # machine the tests run on" is not a failure mode worth having, so the
  # algorithm (Drepper's SHA-crypt) is here in full. Verified against the
  # published test vectors AND against this server's own glibc.
  module Sha512Crypt
    # crypt(3)'s alphabet, which is NOT standard base64 and not in the same
    # order as one.
    ALPHABET = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".freeze
    # glibc's default and what `doveadm pw -s SHA512-CRYPT` produces. Kept at
    # the default so an operator can verify a digest with the stock tool; a
    # different value here would make every hand-check look like a mismatch.
    DEFAULT_ROUNDS = 5_000
    SALT_LENGTH    = 16

    module_function

    def hash(password, salt, rounds = DEFAULT_ROUNDS)
      pw   = password.to_s.b
      salt = salt.to_s.b

      b = Digest::SHA512.digest(pw + salt + pw)

      a = Digest::SHA512.new
      a << pw << salt << repeat(b, pw.bytesize)
      # For each bit of the password length, low bit first: B if set, the
      # password itself if not.
      n = pw.bytesize
      while n.positive?
        a << (n.odd? ? b : pw)
        n >>= 1
      end
      a = a.digest

      p_seq = repeat(Digest::SHA512.digest(pw * pw.bytesize), pw.bytesize)
      s_seq = repeat(Digest::SHA512.digest(salt * (16 + a.getbyte(0))), salt.bytesize)

      c = a
      rounds.times do |i|
        ctx = Digest::SHA512.new
        ctx << (i.odd? ? p_seq : c)
        ctx << s_seq unless (i % 3).zero?
        ctx << p_seq unless (i % 7).zero?
        ctx << (i.odd? ? c : p_seq)
        c = ctx.digest
      end

      encode(c.bytes)
    end

    # "$6$<salt>$<hash>", with the rounds prefix only when it is not the
    # default — that is how glibc spells it, and a digest that spells the
    # default explicitly is compared unequal by nothing but still differs from
    # what every other tool emits.
    def crypt(password, salt: random_salt, rounds: DEFAULT_ROUNDS)
      prefix = rounds == DEFAULT_ROUNDS ? "$6$" : "$6$rounds=#{rounds}$"
      "#{prefix}#{salt}$#{hash(password, salt, rounds)}"
    end

    # Re-hashes `password` with the salt and round count taken from an existing
    # digest, so the caller can compare. Returns nil for anything not shaped
    # like a SHA512-CRYPT digest, so a corrupt column fails closed.
    def rehash(password, digest)
      match = digest.to_s.match(%r{\A\$6\$(?:rounds=(\d+)\$)?([A-Za-z0-9./]{1,16})\$[A-Za-z0-9./]{86}\z})
      return nil unless match

      crypt(password, salt: match[2], rounds: (match[1] || DEFAULT_ROUNDS).to_i)
    end

    def random_salt
      Array.new(SALT_LENGTH) { ALPHABET[SecureRandom.random_number(ALPHABET.length)] }.join
    end

    # Repeat `block` until exactly `length` bytes are available.
    def repeat(block, length)
      return "".b unless length.positive?

      (block * ((length + block.bytesize - 1) / block.bytesize)).byteslice(0, length)
    end

    # crypt(3) reads the 64 digest bytes in a fixed, thoroughly non-obvious
    # permutation, three at a time, little-endian within each group. The
    # indices are (22g, 22g+21, 22g+42) mod 63 for g in 0...21, then the 64th
    # byte alone.
    def encode(bytes)
      out = +""
      21.times do |g|
        i = 22 * g % 63
        word = (bytes[i] << 16) | (bytes[(i + 21) % 63] << 8) | bytes[(i + 42) % 63]
        4.times do
          out << ALPHABET[word & 0x3f]
          word >>= 6
        end
      end
      word = bytes[63]
      2.times do
        out << ALPHABET[word & 0x3f]
        word >>= 6
      end
      out
    end
  end

  # Unambiguous when read aloud or copied off a screen: no 0/O, 1/l/I. 22
  # characters of a 54-character alphabet is ~126 bits, which is well past the
  # point where the round count matters.
  PASSWORD_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".chars.freeze
  PASSWORD_LENGTH   = 22

  belongs_to :mail_domain

  # Secrets are stored encrypted at rest (keys configured from .env in
  # config/initializers/active_record_encryption.rb). Non-deterministic: nothing
  # ever queries by digest, and deterministic encryption would leak that two
  # mailboxes share a password — which is exactly the fact that made this
  # server's mail a liability.
  encrypts :password_digest

  normalizes :local_part, with: ->(v) { v.to_s.strip.downcase.presence }

  validates :local_part, presence: true,
                         uniqueness: { scope: :mail_domain_id, case_sensitive: false }
  validates :quota_bytes, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  validate :local_part_is_safe
  validate :password_digest_is_safe
  validate :does_not_shadow_an_alias

  scope :active,      -> { where(active: true) }
  scope :credentialed, -> { where.not(password_digest: nil) }
  scope :ordered,     -> { joins(:mail_domain).order("mail_domains.name", :local_part) }

  def address = mail_domain && local_part ? "#{local_part}@#{mail_domain.name}" : nil

  # Dovecot's home. The Maildir sits inside it, which is the layout the 143 MB
  # already on disk uses; neither path is stored, because a stored path is a
  # path someone can point at another mailbox.
  def home_path = mail_domain && local_part ? "#{MailConfig::MAILDIR_ROOT}/#{mail_domain.name}/#{local_part}" : nil

  def maildir_path = home_path && "#{home_path}/Maildir"

  # What Postfix's vmailbox map holds: relative to virtual_mailbox_base, with
  # the trailing slash that means "maildir, not mbox".
  def relative_maildir = mail_domain && local_part ? "#{mail_domain.name}/#{local_part}/Maildir/" : nil

  def unlimited_quota? = quota_bytes.blank?

  # No digest means no line in the Dovecot passwd-file at all, so there is
  # nothing to authenticate against. All nine rows start this way.
  def credentialed? = password_digest.present?

  def password_reset_required? = !credentialed?

  # Receives mail through this server. False for info@mos-safeguards.com, whose
  # MX is TransIP — the mailbox is readable, but new mail lands elsewhere.
  def receives_mail? = active? && mail_domain.present? && mail_domain.accepts_mail?

  # Can log in over IMAP/POP3. Deliberately independent of receives_mail?.
  def can_authenticate? = active? && credentialed? && mail_domain.present? && mail_domain.active?

  # Assign a plaintext password. Write-only by construction: the plaintext is
  # hashed here and the argument goes out of scope. There is no reader, and
  # adding one would recreate Plesk's problem.
  def password=(plaintext)
    self.password_digest = plaintext.presence && Sha512Crypt.crypt(plaintext)
    self.password_set_at = plaintext.presence && Time.current
  end

  # Generates a password, stores only its digest, and RETURNS THE PLAINTEXT to
  # the caller — once. Nothing persists it; if the caller drops it on the floor
  # the only recourse is to reset again, which is the correct trade.
  def reset_password!
    plaintext = self.class.generate_password
    self.password = plaintext
    save!
    plaintext
  end

  # Constant-time, so a wrong password cannot be distinguished from a wrong
  # address by timing. Also the only supported way to check a digest, since
  # there is no reader for the plaintext.
  def authenticate(plaintext)
    return false if password_digest.blank? || plaintext.to_s.empty?

    candidate = Sha512Crypt.rehash(plaintext, password_digest)
    return false if candidate.nil?

    ActiveSupport::SecurityUtils.secure_compare(candidate, password_digest)
  end

  def self.generate_password
    Array.new(PASSWORD_LENGTH) { PASSWORD_ALPHABET[SecureRandom.random_number(PASSWORD_ALPHABET.length)] }.join
  end

  private

  def local_part_is_safe
    return if local_part.blank?

    MailConfig.safe_local_part!(local_part)
  rescue MailConfig::UnsafeValue => e
    errors.add(:local_part, e.message)
  end

  # The mirror of MailAlias#does_not_shadow_a_mailbox, and it has to exist on
  # both sides. MailConfig#render validates EVERY row set before it renders ANY
  # file, so one legal save on this side does not merely produce a bad `virtual`
  # — it makes all six files unrenderable, including vmailbox, the passwd-file
  # and the main.cf fragment, none of which involve aliases. The render-time
  # check in alias_rows stays as the backstop for a row written by something
  # else; this is the one that refuses while a human is still looking at it.
  #
  # A disabled alias counts too, exactly as a disabled alias may not be created
  # over an existing mailbox: otherwise enabling it later is the save that
  # breaks rendering, and by then nobody is looking at this pair.
  def does_not_shadow_an_alias
    return if local_part.blank? || mail_domain_id.blank?

    if MailAlias.where(mail_domain_id: mail_domain_id, local_part: local_part).exists?
      errors.add(:local_part,
                 "is already an alias on this domain. Postfix applies alias maps first, so the " \
                 "alias would divert this mailbox's mail instead of it being delivered.")
    end
  end

  # Checked on the way IN as well as at render time. A digest that would break
  # the passwd-file must be refused while someone is still looking at the
  # record, not at 03:00 when the renderer refuses to write the file and every
  # mailbox loses authentication at once.
  def password_digest_is_safe
    return if password_digest.blank?

    MailConfig.safe_digest!(password_digest)
  rescue MailConfig::UnsafeValue => e
    errors.add(:password_digest, e.message)
  end
end
