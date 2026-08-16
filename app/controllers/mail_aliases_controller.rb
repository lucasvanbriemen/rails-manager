class MailAliasesController < ApplicationController
  before_action :set_domain
  before_action :set_alias, only: %i[edit update destroy]

  def new
    return forbidden if cannot?(:create, :apps)

    @mail_alias = @domain.mail_aliases.new(enabled: true, destinations: [])
  end

  def create
    return forbidden if cannot?(:create, :apps)

    @mail_alias = @domain.mail_aliases.new(alias_params)
    if @mail_alias.save
      redirect_to @domain, notice: "Added #{@mail_alias.source}."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    forbidden if cannot?(:update, :apps)
  end

  def update
    return forbidden if cannot?(:update, :apps)

    if @mail_alias.update(alias_params)
      redirect_to @domain, notice: "Saved #{@mail_alias.source}."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    return forbidden if cannot?(:delete, :apps)

    source = @mail_alias.source
    @mail_alias.destroy
    redirect_to @domain, notice: "Removed #{source}."
  end

  private

  def set_domain
    @domain = MailDomain.find(params[:mail_domain_id])
  end

  def set_alias
    @mail_alias = @domain.mail_aliases.find(params[:id])
  end

  def alias_params
    params.require(:mail_alias)
          .permit(:local_part, :enabled, :notes)
          .merge(destinations: destinations)
  end

  # One address per line, never a comma-separated string. MailAlias stores an
  # array for the same reason ProcessService stores argv: Postfix joins multiple
  # destinations with ", " at render time, so if the separator were allowed
  # inside the data a comma typed into this box would silently become a second
  # recipient. Splitting on newlines only keeps a typed comma inside one element,
  # where the address validation rejects it.
  def destinations
    params[:mail_alias][:destinations_text].to_s.split("\n").map(&:strip).compact_blank
  end
end
