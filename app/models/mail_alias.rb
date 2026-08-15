# One `virtual_alias_maps` entry: an address here that is really an address
# somewhere else.
#
# Destinations are an ARRAY, never a comma-separated string, for the same reason
# ProcessService#argv is an array and not a command line. Postfix joins multiple
# destinations with ", " in a single map value, so storing the joined form would
# put the separator inside the data — and a `,` typed into an address field
# would silently become a second recipient. Every element is validated as a
# whole address and the join happens at render time, where nothing user-supplied
# can reach the separator.
#
# Nothing was imported into this table. Most of the 44 entries in Plesk's
# virtual map are its own plumbing: drweb@, kluser@, anonymous@ and
# mailer-daemon@ on every domain pointing at localhost.localdomain. None of that
# survives Plesk, and copying it would import the shape being escaped.
#
# The nine identity entries in there (admin@lucasvanbriemen.nl ->
# admin@lucasvanbriemen.nl, one per mailbox) are a different thing and are NOT
# dismissed: they are the guard that stops an "@domain" catch-all from
# swallowing the domain's own mailboxes. MailConfig#catch_all_rows renders them
# from the mailbox table for any domain that forwards, so they are derived
# rather than stored — a row in this table is only ever a real redirection.
class MailAlias < ApplicationRecord
  belongs_to :mail_domain

  normalizes :local_part, with: ->(v) { v.to_s.strip.downcase.presence }

  validates :local_part, presence: true,
                         uniqueness: { scope: :mail_domain_id, case_sensitive: false }

  validate :local_part_is_safe
  validate :destinations_are_safe
  validate :does_not_shadow_a_mailbox

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { joins(:mail_domain).order("mail_domains.name", :local_part) }

  def source = mail_domain && local_part ? "#{local_part}@#{mail_domain.name}" : nil

  def destination_list = destinations.is_a?(Array) ? destinations.compact_blank : []

  # Display only. The rendered map line is built from the validated array, not
  # from this.
  def destination_preview = destination_list.join(", ")

  private

  def local_part_is_safe
    return if local_part.blank?

    MailConfig.safe_local_part!(local_part)
  rescue MailConfig::UnsafeValue => e
    errors.add(:local_part, e.message)
  end

  def destinations_are_safe
    unless destinations.is_a?(Array)
      errors.add(:destinations, "must be an array of addresses, not a comma-separated string")
      return
    end

    list = destination_list
    return errors.add(:destinations, "must have at least one address") if list.empty?

    list.each do |destination|
      MailConfig.safe_address!(destination, field: "destination")
    rescue MailConfig::UnsafeValue => e
      errors.add(:destinations, e.message)
    end
  end

  # Postfix consults virtual_alias_maps BEFORE virtual_mailbox_maps, so an alias
  # whose source is also a mailbox does not "also" forward — it replaces
  # delivery entirely, and the mailbox silently stops receiving. Nothing about
  # the resulting config looks wrong, which is why this is a validation and not
  # a note in the UI.
  def does_not_shadow_a_mailbox
    return if local_part.blank? || mail_domain_id.blank?

    if Mailbox.where(mail_domain_id: mail_domain_id, local_part: local_part).exists?
      errors.add(:local_part,
                 "is already a mailbox on this domain. Postfix applies alias maps first, so this " \
                 "alias would divert the mailbox's mail instead of copying it.")
    end
  end
end
