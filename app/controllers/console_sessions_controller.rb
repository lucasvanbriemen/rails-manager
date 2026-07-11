# A console session is remote code execution as the ltvb user — same trust
# level as deploying (post_deploy_commands already run arbitrary shell), so
# every action requires :update on :apps.
class ConsoleSessionsController < ApplicationController
  before_action :set_app

  def create
    return forbidden if cannot?(:update, :apps)
    return redirect_to @app, alert: "Consoles are for rails apps." unless @app.rails_app?

    ConsoleSession.sweep_orphans!
    if ConsoleSession.open_now.count >= ConsoleSession::MAX_OPEN
      return redirect_to @app, alert: "Too many open console sessions — close one first."
    end

    session = @app.console_sessions.create!(started_by: current_account&.dig("email"))
    ConsoleSessionJob.perform_later(session.id)
    redirect_to app_console_session_path(@app, session)
  end

  def show
    return forbidden if cannot?(:update, :apps)

    ConsoleSession.sweep_orphans!
    @session = @app.console_sessions.find(params[:id])

    respond_to do |format|
      format.html
      format.json do
        render json: {
          status: @session.status,
          close_reason: @session.close_reason,
          finished: @session.finished?,
          pending: @session.pending_input.present?,
          output: @session.output
        }
      end
    end
  end

  def input
    return forbidden if cannot?(:update, :apps)

    session = @app.console_sessions.find(params[:id])
    if session.submit_input(params.require(:command).to_s)
      head :ok
    else
      head :conflict
    end
  end

  def destroy
    return forbidden if cannot?(:update, :apps)

    session = @app.console_sessions.find(params[:id])
    session.request_close!
    ConsoleSession.sweep_orphans! # a dead worker won't see the request
    redirect_to @app, notice: "Console session closed."
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end
end
