class ExceptionGroupsController < ApplicationController
  before_action :set_app
  before_action :set_group, only: %i[show resolve reopen]

  def index
    return forbidden if cannot?(:read, :apps)

    @filter = params[:filter] == "resolved" ? "resolved" : "open"
    @groups = @app.exception_groups.where(status: @filter).recent
    @resolved_count = @app.exception_groups.where(status: "resolved").count
    @open_count     = @app.exception_groups.open_status.count
  end

  def show
    return forbidden if cannot?(:read, :apps)

    @events = @group.exception_events.limit(20)
  end

  def resolve
    return forbidden if cannot?(:update, :apps)

    @group.resolve!
    redirect_to app_exception_groups_path(@app), notice: "Resolved #{@group.exception_class}."
  end

  def reopen
    return forbidden if cannot?(:update, :apps)

    @group.reopen!
    redirect_to app_exception_group_path(@app, @group), notice: "Reopened."
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end

  def set_group
    @group = @app.exception_groups.find(params[:id])
  end
end
