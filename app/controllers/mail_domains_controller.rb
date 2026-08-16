class MailDomainsController < ApplicationController
  before_action :set_domain, only: %i[show edit update destroy]

  def index
    return forbidden if cannot?(:read, :apps)

    @domains = MailDomain.ordered.includes(:mailboxes, :mail_aliases).to_a
    @mailbox_count = Mailbox.count
    @alias_count   = MailAlias.count
    @uncredentialed = Mailbox.where(password_digest: nil).count
  end

  def show
    return forbidden if cannot?(:read, :apps)

    @mailboxes = @domain.mailboxes.order(:local_part)
    @aliases   = @domain.mail_aliases.order(:local_part)
  end

  def new
    return forbidden if cannot?(:create, :apps)

    @domain = MailDomain.new(active: true, local_delivery: true, catch_all: "reject")
  end

  def create
    return forbidden if cannot?(:create, :apps)

    @domain = MailDomain.new(domain_params)
    if @domain.save
      redirect_to @domain, notice: "Added #{@domain.name}."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    forbidden if cannot?(:update, :apps)
  end

  def update
    return forbidden if cannot?(:update, :apps)

    if @domain.update(domain_params)
      redirect_to @domain, notice: "Saved #{@domain.name}."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Removing the row removes the domain's mailboxes and aliases with it
  # (dependent: :destroy) — but NOT the Maildirs under MailConfig::MAILDIR_ROOT.
  # 143 MB of real mail lives there and nothing in this app deletes it; the
  # confirmation text says so, because "delete domain" reads like it would.
  def destroy
    return forbidden if cannot?(:delete, :apps)

    name = @domain.name
    @domain.destroy
    redirect_to mail_path, notice: "Removed #{name}. Its Maildirs are left on disk."
  end

  private

  def set_domain
    @domain = MailDomain.find(params[:id])
  end

  def domain_params
    params.require(:mail_domain).permit(:name, :active, :local_delivery, :dkim_selector,
                                        :catch_all, :catch_all_target, :notes)
  end
end
