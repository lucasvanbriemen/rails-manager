class MailboxesController < ApplicationController
  # A floor, not a strength meter. The nine imported accounts shared one
  # 15-character password, so length was never the thing that was wrong with
  # them — but a box that accepts "abc" is worth refusing, and anything cleverer
  # here would just be a rule to work around.
  MINIMUM_PASSWORD_LENGTH = 12

  before_action :set_domain
  before_action :set_mailbox, only: %i[edit update destroy reset_password set_password]

  def new
    return forbidden if cannot?(:create, :apps)

    @mailbox = @domain.mailboxes.new(active: true)
  end

  # Created without a credential on purpose. A mailbox with no digest gets no
  # line in the Dovecot passwd-file at all, so it receives mail but nobody can
  # log in until someone presses "Generate password" — the same rule the
  # migration applied to all nine imported accounts, enforced rather than
  # remembered.
  def create
    return forbidden if cannot?(:create, :apps)

    @mailbox = @domain.mailboxes.new(mailbox_params)
    if @mailbox.save
      redirect_to @domain, notice: "Added #{@mailbox.address}. It cannot authenticate until you set a password."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    forbidden if cannot?(:update, :apps)
  end

  def update
    return forbidden if cannot?(:update, :apps)

    if @mailbox.update(mailbox_params)
      redirect_to @domain, notice: "Saved #{@mailbox.address}."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # The plaintext exists exactly once, here. Mailbox#reset_password! returns it
  # and nothing persists it, so it goes straight into the flash for the one
  # render that follows; there is no way to ask for it again.
  def reset_password
    return forbidden if cannot?(:update, :apps)

    password = @mailbox.reset_password!
    redirect_to @domain, flash: { password_for: @mailbox.address, password: password }
  end

  # Choose a password rather than take a generated one — for an account whose
  # owner already has a password they expect to keep working, which a generated
  # one cannot serve.
  #
  # Its own action, not part of #update, because Mailbox#password= treats blank
  # as "no credential": were it in mailbox_params, saving the settings form
  # without touching the password field would silently wipe the digest and drop
  # the mailbox out of the Dovecot passwd-file.
  def set_password
    return forbidden if cannot?(:update, :apps)

    password = params.dig(:mailbox, :password).to_s

    if password.length < MINIMUM_PASSWORD_LENGTH
      return redirect_to edit_mail_domain_mailbox_path(@domain, @mailbox),
                         alert: "Password must be at least #{MINIMUM_PASSWORD_LENGTH} characters."
    end

    unless password == params.dig(:mailbox, :password_confirmation).to_s
      return redirect_to edit_mail_domain_mailbox_path(@domain, @mailbox),
                         alert: "The two passwords did not match. Nothing was changed."
    end

    @mailbox.password = password
    @mailbox.save!
    redirect_to @domain, notice: "Password set for #{@mailbox.address}."
  end

  def destroy
    return forbidden if cannot?(:delete, :apps)

    address = @mailbox.address
    @mailbox.destroy
    redirect_to @domain, notice: "Removed #{address}. Its Maildir is left on disk."
  end

  private

  def set_domain
    @domain = MailDomain.find(params[:mail_domain_id])
  end

  def set_mailbox
    @mailbox = @domain.mailboxes.find(params[:id])
  end

  def mailbox_params
    params.require(:mailbox)
          .permit(:local_part, :active, :notes)
          .merge(quota_bytes: quota_bytes)
  end

  # An amount and a unit rather than a free-text size: the column is bytes, and
  # a box that accepts "2 GB" has to decide what "2 G" and "2gb" mean. Blank
  # amount is unlimited, which is what every mailbox is today.
  def quota_bytes
    amount = params[:mailbox][:quota_amount]
    return nil if amount.blank?

    multiplier = params[:mailbox][:quota_unit] == "GB" ? 1024**3 : 1024**2
    (amount.to_f * multiplier).round
  end
end
