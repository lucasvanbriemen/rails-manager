class MailboxesController < ApplicationController
  before_action :set_domain
  before_action :set_mailbox, only: %i[edit update destroy reset_password]

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
