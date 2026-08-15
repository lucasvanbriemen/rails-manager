# A domain this server knows something about, mail-wise.
#
# The field that matters is `local_delivery`, and it exists because the running
# server has this wrong for half its domains. Postfix's
# `virtual_mailbox_domains` is not a list of "domains we care about" — it is a
# list of domains this machine declares itself the FINAL DESTINATION for. For a
# domain in that list Postfix looks up the recipient in `virtual_mailbox_maps`,
# finds nothing, and rejects; it never falls through to DNS. So listing a domain
# whose MX points somewhere else does not make this server helpful, it makes it
# a black hole.
#
# Six domains are listed today. Three have MX here (ltvb.nl,
# lucasvanbriemen.nl, voordezorgmanagement.nl). The other three point at
# smtp.rzone.de and mx.transip.email — and this server rejects mail it sends to
# them, including its own applications' mail. `local_delivery: false` is the fix:
# the domain drops out of virtual_mailbox_domains, Postfix does the ordinary MX
# lookup, and the mail goes where the DNS says it should.
class MailDomain < ApplicationRecord
  # Only the two policies that render differently. Plesk also offers "bounce",
  # but for a virtual domain Postfix has no way to accept-then-bounce that is
  # distinguishable from rejecting at RCPT time — both end as a 550 to the
  # sender. A third policy that rendered identically to an existing one would be
  # a lie in the UI, so it is not offered.
  CATCH_ALL_POLICIES = %w[reject forward].freeze

  # RFC 2142 requires postmaster on any domain that receives mail; abuse is
  # required of anyone who wants their mail accepted by the large providers.
  REQUIRED_ADDRESSES = %w[postmaster abuse].freeze

  has_many :mailboxes, dependent: :destroy
  has_many :mail_aliases, dependent: :destroy

  # A trailing dot is a legal way to write a FQDN and would produce a map key
  # that never matches what Postfix looks up.
  normalizes :name, with: ->(v) { v.to_s.strip.downcase.delete_suffix(".").presence }
  normalizes :dkim_selector, with: ->(v) { v.to_s.strip.downcase.presence }
  normalizes :catch_all_target, with: ->(v) { v.to_s.strip.downcase.presence }

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :catch_all, inclusion: { in: CATCH_ALL_POLICIES }
  validates :catch_all_target, presence: { message: "is required when catch-all forwards" },
                               if: :forwards_catch_all?

  validate :name_is_safe
  validate :dkim_selector_is_safe
  validate :catch_all_target_is_safe

  scope :active,   -> { where(active: true) }
  scope :delivering_locally, -> { active.where(local_delivery: true) }
  scope :ordered,  -> { order(:name) }

  def forwards_catch_all? = catch_all == "forward"

  def signs_dkim? = dkim_selector.present?

  # Where opendkim reads the private key. Derived, never stored: a stored path
  # is a path someone can point at another domain's key and sign as them.
  def dkim_key_path
    return nil unless signs_dkim?

    "#{MailConfig::DKIM_ROOT}/#{name}/#{dkim_selector}"
  end

  # True when Postfix will claim final delivery for this domain.
  def accepts_mail? = active? && local_delivery?

  # Facts about the row, not policy — empty means nothing needs attention, so
  # nothing has to be remembered at cutover time. Same shape as
  # ScheduledJob#promotion_blockers and used the same way.
  def configuration_gaps
    gaps = []
    gaps.concat(local_delivery_gaps)
    gaps.concat(missing_required_addresses) if accepts_mail?
    if !accepts_mail? && signs_dkim?
      gaps << "signs with DKIM but does not accept local delivery; that is fine for a domain " \
              "that only SENDS through this server, and wrong if the MX was meant to point here"
    end
    gaps
  end

  # Every address this domain resolves, mailboxes and aliases together. Used to
  # answer "is there a postmaster" without caring which of the two provides it.
  #
  # "Resolves" has to mean exactly what MailConfig#deliverable_mailboxes means,
  # which is why the mailbox half filters on active? rather than taking the whole
  # association: an inactive mailbox is not in vmailbox, so Postfix 550s mail to
  # it — and counting it here would silence the postmaster gap at precisely the
  # moment it became true.
  def local_parts
    (mailboxes.select(&:active?).map(&:local_part) +
     mail_aliases.select(&:enabled?).map(&:local_part)).uniq
  end

  private

  def local_delivery_gaps
    return [] unless active?

    if accepts_mail? && mailboxes.none?(&:active?) && mail_aliases.none?(&:enabled?)
      [ "accepts local delivery but has no active mailbox or alias, so Postfix rejects every " \
        "recipient at this domain instead of relaying to its MX" ]
    elsif !local_delivery? && mailboxes.any?(&:active?)
      [ "has #{mailboxes.count(&:active?)} active mailbox(es) but local_delivery is off, so new " \
        "mail goes to the domain's MX elsewhere; the existing Maildirs stay readable over IMAP" ]
    else
      []
    end
  end

  def missing_required_addresses
    present = local_parts
    (REQUIRED_ADDRESSES - present).map do |local|
      "has no #{local}@#{name} (RFC 2142); mail to it is rejected"
    end
  end

  # Delegated to MailConfig rather than re-expressed here, because MailConfig is
  # what actually writes the file. Two patterns would drift, and the looser one
  # would be the one that mattered.
  def name_is_safe
    return if name.blank?

    MailConfig.safe_domain!(name)
  rescue MailConfig::UnsafeValue => e
    errors.add(:name, e.message)
  end

  def dkim_selector_is_safe
    return if dkim_selector.blank?

    MailConfig.safe_dkim_selector!(dkim_selector)
  rescue MailConfig::UnsafeValue => e
    errors.add(:dkim_selector, e.message)
  end

  def catch_all_target_is_safe
    return if catch_all_target.blank?

    MailConfig.safe_address!(catch_all_target, field: "catch-all target")
  rescue MailConfig::UnsafeValue => e
    errors.add(:catch_all_target, e.message)
  end
end
