# Workers: the long-running processes beside the apps (Solid Queue workers, the
# standalone ActionCable Puma, Laravel queue workers, the Kokoro TTS server).
#
# Every privileged action goes through Agent rather than PrivilegedShell: the
# old sudo wrapper only knows the seven Plesk verbs, while ltvb-agentd already
# implements the systemd ones. Agent.call never raises — a dead agent, a
# protocol mismatch and a refused parameter all come back as a Result — so the
# screens degrade to "described but not controllable" instead of erroring.
class ProcessServicesController < ApplicationController
  before_action :set_service, only: %i[show edit update destroy start stop restart]

  # systemd.restart's own vocabulary; the agent validates against the same list.
  ACTIONS = { "start" => "start", "stop" => "stop", "restart" => "restart" }.freeze

  # Stands in for an environment value in the unit preview. A plain word rather
  # than a row of dots: it still has to pass the same value validation the real
  # one does, or the preview fails to render for the rows that need it most.
  REDACTED = "REDACTED".freeze

  def index
    return forbidden if cannot?(:read, :apps)

    @services = ProcessService.ordered.includes(:app).to_a
    @statuses = live_statuses(@services)
    @agent    = agent_state
  end

  def show
    return forbidden if cannot?(:read, :apps)

    @agent  = agent_state
    @status = live_statuses([ @service ])[@service.id]
    @lines  = params[:lines].to_i.clamp(50, 2000)
    @lines  = 200 if params[:lines].blank?
    @journal = journal_for(@service, @lines)
    @unit    = rendered_unit
  end

  def new
    return forbidden if cannot?(:create, :apps)

    @service = ProcessService.new(kind: "generic", enabled: true, autostart: true, managed: true,
                                  user: "ltvb", app_id: params[:app_id])
  end

  def create
    return forbidden if cannot?(:create, :apps)

    @service = ProcessService.new(service_params)
    if @service.save
      redirect_to @service, notice: "Added #{@service.name}."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    forbidden if cannot?(:update, :apps)
  end

  def update
    return forbidden if cannot?(:update, :apps)

    if @service.update(service_params)
      redirect_to @service, notice: "Saved #{@service.name}."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Forgetting a worker is not stopping it. The row goes; whatever is running
  # keeps running, exactly as `dependent: :nullify` keeps a unit alive when its
  # app is untracked. Stopping it first is a separate, deliberate button.
  def destroy
    return forbidden if cannot?(:delete, :apps)

    name = @service.name
    @service.destroy
    redirect_to process_services_path,
                notice: "Removed the record for #{name}. Anything running under that name was left alone."
  end

  def start   = run_action("start")
  def stop    = run_action("stop")
  def restart = run_action("restart")

  private

  def set_service
    @service = ProcessService.find(params[:id])
  end

  def run_action(action)
    return forbidden if cannot?(:update, :apps)

    result = Agent.call("systemd.restart", unit: @service.unit_name, action: ACTIONS.fetch(action))

    if result.ok
      redirect_to @service, notice: "#{action.capitalize}ed #{@service.unit_name}."
    else
      redirect_to @service, alert: "Could not #{action} #{@service.unit_name}: #{result.err.presence || 'the agent refused'}"
    end
  end

  # One handshake for the whole page rather than one per worker: Agent caches a
  # successful handshake for a minute but never caches a failure, so a down
  # agent would otherwise be dialled once per row.
  def agent_state
    return @agent_state if defined?(@agent_state)

    @agent_state = Agent.available? ? { up: true, verbs: Agent.verbs } : { up: false, verbs: [] }
  end

  def live_statuses(services)
    return {} unless agent_state[:up] && agent_state[:verbs].include?("systemd.status")

    services.index_with { |service|
      result = Agent.call("systemd.status", unit: service.unit_name, timeout: 15)
      result.ok ? result.data : nil
    }.transform_keys(&:id)
  end

  def journal_for(service, lines)
    return nil unless agent_state[:up] && agent_state[:verbs].include?("systemd.journal")

    result = Agent.call("systemd.journal", unit: service.unit_name, lines: lines, timeout: 30)
    result.ok ? result.output : "(#{result.err.presence || 'the agent refused'})"
  end

  # The unit file this row WOULD produce. Worth showing for an adopted worker
  # especially: it is the diff between what the manager would write and the
  # hand-written unit or supervisor program that owns the process today.
  #
  # Rendered from a copy whose environment VALUES are redacted. The real file is
  # installed 0600 precisely because its Environment= lines carry RAILS_MASTER_KEY
  # and API tokens; printing them into a page anyone with read access can open
  # would undo that, and the Definition card above deliberately shows only keys.
  def rendered_unit
    preview = @service.dup
    preview.environment = @service.environment.to_h.transform_values { REDACTED }
    preview.render_unit
  rescue StandardError => e
    "(cannot render: #{e.message})"
  end

  def service_params
    params.require(:process_service)
          .permit(:name, :kind, :app_id, :user, :working_directory, :autostart, :managed,
                  :enabled, :notes)
          .merge(argv: argv, environment: environment)
  end

  # One argument per line, never a command string: supervisor's `command=` is a
  # string it splits itself, which puts every value one quoting bug away from
  # being a second command. An ExecStart built from a validated array has no
  # shell in it to escape from, and this is the boundary where that starts.
  def argv
    params[:process_service][:argv_text].to_s.split("\n").map(&:strip).compact_blank
  end

  # KEY=value per line. Split on the FIRST "=" only, so a value containing one
  # (a DATABASE_URL, a base64 secret) survives intact.
  def environment
    params[:process_service][:environment_text].to_s.lines.filter_map { |line|
      line = line.strip
      next if line.blank? || line.start_with?("#")

      key, value = line.split("=", 2)
      next if value.nil?

      [ key.strip, value.strip ]
    }.to_h
  end
end
