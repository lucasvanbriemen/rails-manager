require "test_helper"

class MailDomainsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @domain = MailDomain.create!(name: "example.test", active: true, local_delivery: true,
                                 catch_all: "reject")
  end

  test "the index lists domains" do
    get mail_path, headers: as
    assert_response :success
    assert_includes response.body, "example.test"
  end

  test "reading is refused without the permission" do
    get mail_path
    assert_redirected_to %r{\Ahttps://login\.ltvb\.nl}
  end

  test "creating is refused with read-only permission" do
    assert_no_difference -> { MailDomain.count } do
      post mail_domains_path, params: { mail_domain: { name: "nope.test" } },
                              headers: as({ "apps" => %w[read] })
    end
  end

  test "creates a domain" do
    assert_difference -> { MailDomain.count }, 1 do
      post mail_domains_path,
           params: { mail_domain: { name: "New.Test.", active: "1", local_delivery: "1",
                                    catch_all: "reject" } },
           headers: as
    end
    # normalizes strips the trailing dot and downcases: a trailing dot is a legal
    # FQDN spelling that would produce a map key Postfix never looks up.
    assert_equal "new.test", MailDomain.order(:created_at).last.name
  end

  test "re-renders with an error rather than saving an unsafe name" do
    assert_no_difference -> { MailDomain.count } do
      post mail_domains_path, params: { mail_domain: { name: "not a domain", catch_all: "reject" } },
                              headers: as
    end
    assert_response :unprocessable_entity
  end

  test "a forwarding catch-all requires a target" do
    patch mail_domain_path(@domain),
          params: { mail_domain: { catch_all: "forward", catch_all_target: "" } },
          headers: as
    assert_response :unprocessable_entity
    assert_equal "reject", @domain.reload.catch_all
  end

  test "turning local delivery off is what takes the domain out of virtual_mailbox_domains" do
    patch mail_domain_path(@domain), params: { mail_domain: { local_delivery: "0" } }, headers: as
    assert_not @domain.reload.local_delivery?
    assert_not @domain.accepts_mail?
  end

  test "destroying takes its mailboxes with it" do
    @domain.mailboxes.create!(local_part: "postmaster")

    assert_difference -> { Mailbox.count }, -1 do
      delete mail_domain_path(@domain), headers: as
    end
    assert_redirected_to mail_path
  end

  test "destroying is refused without the delete permission" do
    assert_no_difference -> { MailDomain.count } do
      delete mail_domain_path(@domain), headers: as({ "apps" => %w[read update] })
    end
  end
end
