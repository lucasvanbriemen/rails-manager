class AppsController < ApplicationController
  before_action :set_app, only: %i[show edit update destroy deploy logs]

  def index
    redirect_to root_path
  end

  def show
    return forbidden if cannot?(:read, :apps)

    @status = AppStatusChecker.check(@app) if @app.rails_app?
    @deployments = @app.deployments.limit(20)
    @deliveries = @app.webhook_deliveries.limit(5)
    @open_exceptions = @app.exception_groups.open_status.recent.limit(5)
    @open_exception_count = @app.exception_groups.open_status.count
    @process_services = @app.process_services.ordered
  end

  def new
    return forbidden if cannot?(:create, :apps)

    @app = App.new(app_kind: params[:app_kind].presence || "rails",
                   ruby_version: "3.3.8", git_branch: "master",
                   primary_db_kind: "external")
  end

  def create
    return forbidden if cannot?(:create, :apps)

    @app = App.new(app_params)
    if @app.save
      # "create" provisions a Plesk subdomain. An apex domain is the webspace —
      # it already exists, and asking Plesk to create a subdomain with a blank
      # name is at best an error, so the apex site goes straight to a deploy.
      kind = @app.apex? ? "deploy" : "create"
      deployment = @app.deployments.create!(kind: kind, triggered_by: admin_email)
      enqueue(deployment)
      redirect_to app_deployment_path(@app, deployment), notice: "Creating #{@app.fqdn}…"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    forbidden if cannot?(:update, :apps)
  end

  def update
    return forbidden if cannot?(:update, :apps)

    if @app.update(app_params)
      redirect_to @app, notice: "Saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Untracking now tears down: AppTeardown stops and forgets the app's workers
  # and deletes its files, then the record goes. It refuses to delete anything
  # it cannot prove belongs to this app alone — an apex site's directory is the
  # webspace, and a shared checkout is every other app's too — and says so in
  # the notice rather than failing silently.
  def destroy
    return forbidden if cannot?(:delete, :apps)

    label = @app.repo? ? @app.name : @app.fqdn
    steps = AppTeardown.call(@app)

    # An apex domain IS the webspace: `remove-subdomain` with a blank name asks
    # Plesk to delete the whole subscription, every other app under it included.
    # Removing a domain is a Plesk decision, not this tool's.
    unless @app.repo? || @app.apex?
      result = Plesk.remove_subdomain(@app.subdomain, @app.domain)
      steps << (result.ok ? "removed the Plesk subdomain" : "Plesk said: #{result.err}")
    end

    @app.destroy
    redirect_to root_path, notice: "Stopped managing #{label}#{" — #{steps.join('; ')}" if steps.any?}."
  end

  # --- member deploy actions ---

  def deploy
    return forbidden if cannot?(:update, :apps)

    deployment = @app.deployments.create!(kind: "deploy", triggered_by: admin_email, ref: params[:ref].presence)
    enqueue(deployment)
    redirect_to app_deployment_path(@app, deployment), notice: "Deploying…"
  end

  def logs
    return forbidden if cannot?(:read, :apps)

    @files = LogFiles.for(@app)
    @file  = params[:file].present? ? LogFiles.find(@app, params[:file]) : LogFiles.default(@app)
    return head :not_found if params[:file].present? && @file.nil?

    @lines   = LogFiles::LINE_CHOICES.find { |n| n == params[:lines].to_i } || LogFiles::LINE_CHOICES.first
    @content = @file ? LogFiles.tail(@file.path, lines: @lines) : "(no log files found)"

    respond_to do |format|
      format.html
      format.json { render json: { content: @content, size: @file&.size, mtime: @file&.mtime } }
      format.text do
        send_data @content, type: "text/plain",
                            filename: "#{@app.name.parameterize}-#{@file&.id.to_s.tr(':', '-').presence || 'log'}.log"
      end
    end
  end

  private

  def set_app
    @app = App.find(params[:id])
  end

  def admin_email
    current_account["email"]
  end

  def enqueue(deployment, allow_upload: true)
    DeployJob.perform_later(deployment.id, ref: deployment.ref)
  end

  def save_upload
    dir = Rails.root.join("tmp", "uploads")
    FileUtils.mkdir_p(dir)
    path = dir.join("app-#{@app.id}-#{SecureRandom.hex(6)}.tar.gz").to_s
    File.binwrite(path, params[:tarball].read)
    path
  end

  def app_params
    params.require(:app).permit(
      :name, :app_kind, :subdomain, :domain, :ruby_version,
      :git_repo_url, :git_branch, :primary_db_kind, :notes,
      :deploy_path, :post_deploy_commands,
      :master_key, :env_text,
      :auto_deploy, :webhook_secret, :webhook_branch,
      # Serving customisations. Each of these is rendered into an nginx config
      # that root parses; App validates them and NginxConfig validates them
      # again before writing a byte.
      :apex_confirmed, :doc_root_suffix, :redirect_http, :hsts, :default_server,
      :cable_path, :cable_port, :xaccel_path, :ip_allowlist
    )
  end
end
