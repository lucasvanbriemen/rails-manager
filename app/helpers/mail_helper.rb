module MailHelper
  # The quota column is bytes; the form edits an amount and a unit so nothing
  # has to parse "2 GB" / "2G" / "2gb". Round numbers stay round on the way
  # back out: 5368709120 comes back as 5 GB, not 5120 MB.
  GB = 1024**3
  MB = 1024**2

  def quota_unit(mailbox)
    return "GB" if mailbox.quota_bytes.present? && (mailbox.quota_bytes % GB).zero?

    mailbox.quota_bytes.present? ? "MB" : "GB"
  end

  def quota_amount(mailbox)
    return nil if mailbox.quota_bytes.blank?

    divisor = quota_unit(mailbox) == "GB" ? GB : MB
    value   = mailbox.quota_bytes.to_f / divisor
    (value % 1).zero? ? value.to_i : value.round(2)
  end
end
