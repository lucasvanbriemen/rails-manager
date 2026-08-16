require "test_helper"

class MailboxesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @domain = MailDomain.create!(name: "example.test", active: true, local_delivery: true,
                                 catch_all: "reject")
  end

  test "a new mailbox has no credential, so nothing can authenticate as it yet" do
    post mail_domain_mailboxes_path(@domain),
         params: { mailbox: { local_part: "Postmaster", active: "1" } }, headers: as

    mailbox = @domain.mailboxes.sole
    assert_equal "postmaster", mailbox.local_part
    assert_not mailbox.credentialed?
    assert_not mailbox.can_authenticate?
  end

  test "quota is stored in bytes from an amount and a unit" do
    post mail_domain_mailboxes_path(@domain),
         params: { mailbox: { local_part: "a", quota_amount: "2", quota_unit: "GB" } }, headers: as
    assert_equal 2 * 1024**3, @domain.mailboxes.sole.quota_bytes

    post mail_domain_mailboxes_path(@domain),
         params: { mailbox: { local_part: "b", quota_amount: "500", quota_unit: "MB" } }, headers: as
    assert_equal 500 * 1024**2, @domain.mailboxes.find_by(local_part: "b").quota_bytes
  end

  test "a blank amount means unlimited, not zero" do
    post mail_domain_mailboxes_path(@domain),
         params: { mailbox: { local_part: "a", quota_amount: "", quota_unit: "GB" } }, headers: as

    mailbox = @domain.mailboxes.sole
    assert_nil mailbox.quota_bytes
    assert mailbox.unlimited_quota?
  end

  test "clearing the amount on an existing mailbox returns it to unlimited" do
    mailbox = @domain.mailboxes.create!(local_part: "a", quota_bytes: 1024**3)

    patch mail_domain_mailbox_path(@domain, mailbox),
          params: { mailbox: { local_part: "a", quota_amount: "" } }, headers: as
    assert_nil mailbox.reload.quota_bytes
  end

  test "a mailbox may not be created over an existing alias" do
    @domain.mail_aliases.create!(local_part: "info", destinations: [ "someone@example.test" ])

    assert_no_difference -> { Mailbox.count } do
      post mail_domain_mailboxes_path(@domain), params: { mailbox: { local_part: "info" } },
                                                headers: as
    end
    assert_response :unprocessable_entity
  end

  test "resetting shows the plaintext once and stores only a digest" do
    mailbox = @domain.mailboxes.create!(local_part: "a")

    post reset_password_mail_domain_mailbox_path(@domain, mailbox), headers: as
    password = flash[:password]

    assert_equal Mailbox::PASSWORD_LENGTH, password.length
    assert mailbox.reload.authenticate(password)
    assert_not_equal password, mailbox.password_digest
    assert_match %r{\A\$6\$}, mailbox.password_digest
    assert mailbox.password_set_at.present?
  end

  test "a chosen password is stored as a digest that authenticates it" do
    mailbox = @domain.mailboxes.create!(local_part: "a")
    chosen  = "correct-horse-battery-staple"

    patch set_password_mail_domain_mailbox_path(@domain, mailbox),
          params: { mailbox: { password: chosen, password_confirmation: chosen } }, headers: as

    mailbox.reload
    assert mailbox.authenticate(chosen)
    assert_not mailbox.authenticate("something else")
    assert_match %r{\A\$6\$}, mailbox.password_digest
    assert mailbox.password_set_at.present?
  end

  test "a mismatched confirmation changes nothing" do
    mailbox = @domain.mailboxes.create!(local_part: "a")

    patch set_password_mail_domain_mailbox_path(@domain, mailbox),
          params: { mailbox: { password: "a-long-enough-one", password_confirmation: "a-long-enough-two" } },
          headers: as

    assert_not mailbox.reload.credentialed?
  end

  test "a short password is refused" do
    mailbox = @domain.mailboxes.create!(local_part: "a")
    short   = "a" * (MailboxesController::MINIMUM_PASSWORD_LENGTH - 1)

    patch set_password_mail_domain_mailbox_path(@domain, mailbox),
          params: { mailbox: { password: short, password_confirmation: short } }, headers: as

    assert_not mailbox.reload.credentialed?
  end

  # Mailbox#password= reads blank as "no credential", so were the password part
  # of the settings form's params, saving that form without touching the
  # password field would silently drop the mailbox out of the passwd-file.
  test "saving the settings form leaves an existing password alone" do
    mailbox = @domain.mailboxes.create!(local_part: "a")
    mailbox.update!(password: "keep-this-one-please")

    patch mail_domain_mailbox_path(@domain, mailbox),
          params: { mailbox: { local_part: "a", notes: "edited", password: "" } }, headers: as

    assert mailbox.reload.credentialed?
    assert mailbox.authenticate("keep-this-one-please")
  end

  test "setting a password is refused with read-only permission" do
    mailbox = @domain.mailboxes.create!(local_part: "a")

    patch set_password_mail_domain_mailbox_path(@domain, mailbox),
          params: { mailbox: { password: "a-long-enough-one", password_confirmation: "a-long-enough-one" } },
          headers: as({ "apps" => %w[read] })

    assert_not mailbox.reload.credentialed?
  end

  test "resetting is refused with read-only permission" do
    mailbox = @domain.mailboxes.create!(local_part: "a")

    post reset_password_mail_domain_mailbox_path(@domain, mailbox), headers: as({ "apps" => %w[read] })
    assert_not mailbox.reload.credentialed?
  end

  # Looked up through the domain association, never by bare id: otherwise the id
  # in the path decides which mailbox is edited and the domain in the path is
  # decoration.
  test "a mailbox is only reachable through its own domain" do
    other   = MailDomain.create!(name: "other.test", catch_all: "reject")
    mailbox = @domain.mailboxes.create!(local_part: "a")

    get edit_mail_domain_mailbox_path(other, mailbox), headers: as
    assert_response :not_found
  end
end
