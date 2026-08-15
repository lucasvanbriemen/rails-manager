require "test_helper"

# configuration_gaps is the only mechanism that surfaces a missing postmaster
# before the cutover, so what counts as "this domain resolves that address" has
# to be exactly what MailConfig renders — not the whole association.
class MailDomainTest < ActiveSupport::TestCase
  def saved_domain(name = "lucasvanbriemen.nl", **overrides)
    MailDomain.create!({ name: name, active: true, local_delivery: true,
                         catch_all: "reject" }.merge(overrides))
  end

  test "a deactivated mailbox stops closing the gap it used to close" do
    d = saved_domain
    postmaster = d.mailboxes.create!(local_part: "postmaster")
    d.mail_aliases.create!(local_part: "abuse", destinations: [ "postmaster@lucasvanbriemen.nl" ])

    assert_empty d.reload.configuration_gaps

    postmaster.update!(active: false)

    # Postfix now 550s every message to postmaster@: the address is out of
    # vmailbox, so the gap must reappear rather than be remembered by the row.
    assert_not_includes MailConfig.new.render("vmailbox"), "postmaster@lucasvanbriemen.nl"
    assert_includes d.reload.configuration_gaps.to_sentence, "has no postmaster@lucasvanbriemen.nl"
  end

  test "a disabled alias stops closing the gap too" do
    d = saved_domain
    d.mailboxes.create!(local_part: "postmaster")
    abuse = d.mail_aliases.create!(local_part: "abuse", destinations: [ "postmaster@lucasvanbriemen.nl" ])

    abuse.update!(enabled: false)

    assert_includes d.reload.configuration_gaps.to_sentence, "has no abuse@lucasvanbriemen.nl"
  end

  test "local_parts counts what actually resolves, mailboxes and aliases alike" do
    d = saved_domain
    d.mailboxes.create!(local_part: "contact")
    d.mailboxes.create!(local_part: "old", active: false)
    d.mail_aliases.create!(local_part: "sales", destinations: [ "contact@lucasvanbriemen.nl" ])

    assert_equal %w[contact sales], d.reload.local_parts.sort
  end

  test "a domain that accepts mail with nothing behind it says so" do
    # Listing a domain in virtual_mailbox_domains with no recipient makes this
    # server reject every address at it instead of relaying to its MX.
    d = saved_domain("ltvb.nl")

    assert_includes d.configuration_gaps.to_sentence, "rejects every recipient"
  end
end
