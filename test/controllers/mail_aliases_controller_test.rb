require "test_helper"

class MailAliasesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @domain = MailDomain.create!(name: "example.test", active: true, local_delivery: true,
                                 catch_all: "reject")
  end

  test "destinations are split on newlines into an array" do
    post mail_domain_mail_aliases_path(@domain),
         params: { mail_alias: { local_part: "info", enabled: "1",
                                 destinations_text: "  one@example.test \n\n two@example.test \n" } },
         headers: as

    assert_equal %w[one@example.test two@example.test], @domain.mail_aliases.sole.destinations
  end

  # The separator must never come out of the data. Postfix joins destinations
  # with ", " at render time, so a comma typed into the box has to stay inside
  # one element and be rejected there, not silently become a second recipient.
  test "a comma stays inside one address and is rejected as invalid" do
    assert_no_difference -> { MailAlias.count } do
      post mail_domain_mail_aliases_path(@domain),
           params: { mail_alias: { local_part: "info",
                                   destinations_text: "one@example.test, two@example.test" } },
           headers: as
    end
    assert_response :unprocessable_entity
  end

  test "at least one destination is required" do
    assert_no_difference -> { MailAlias.count } do
      post mail_domain_mail_aliases_path(@domain),
           params: { mail_alias: { local_part: "info", destinations_text: "   \n  " } },
           headers: as
    end
    assert_response :unprocessable_entity
  end

  test "an alias may not be created over an existing mailbox" do
    @domain.mailboxes.create!(local_part: "postmaster")

    assert_no_difference -> { MailAlias.count } do
      post mail_domain_mail_aliases_path(@domain),
           params: { mail_alias: { local_part: "postmaster",
                                   destinations_text: "someone@example.test" } },
           headers: as
    end
    assert_response :unprocessable_entity
  end

  test "updates replace the whole destination list" do
    mail_alias = @domain.mail_aliases.create!(local_part: "info",
                                              destinations: %w[one@example.test two@example.test])

    patch mail_domain_mail_alias_path(@domain, mail_alias),
          params: { mail_alias: { local_part: "info", destinations_text: "three@example.test" } },
          headers: as

    assert_equal %w[three@example.test], mail_alias.reload.destinations
  end

  test "destroying is refused without the delete permission" do
    mail_alias = @domain.mail_aliases.create!(local_part: "info", destinations: [ "a@example.test" ])

    assert_no_difference -> { MailAlias.count } do
      delete mail_domain_mail_alias_path(@domain, mail_alias), headers: as({ "apps" => %w[read update] })
    end
  end
end
