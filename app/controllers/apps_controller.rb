class AppsController < ApplicationController
  before_action :set_app, only: %i[show edit update destroy deploy restart migrate_primary logs]

  def index
    redirect_to root_path
  end

  def show
    return forbidden if cannot?(:read, :apps)

    @status = AppStatusChecker.check(@app) if @app.rails_app?
    @deployments = @app.deployments.limit(20)
  end

  def new
    return forbidden if cannot?(:create, :apps)

    @app = App.new(app_kind: params[:app_kind].presence || "rails",
                   ruby_version: "3.3.8", git_branch: "main",
                   source_mode: "git", primary_db_kind: "sqlite")
  end

  def create
    return forbidden if cannot?(:create, :apps)

    @app = App.new(app_params)
    if @app.save
      deployment = @app.deployments.create!(kind: "create", triggered_by: admin_email)
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

  def destroy
    return forbidden if cannot?(:delete, :apps)

    # A repo isn't a Plesk subdomain — just stop tracking it (checkout stays on disk).
    if @app.repo?
      label = @app.name
      @app.destroy
      return redirect_to root_path, notice: "Stopped managing #{label} (on-disk checkout left in place)."
    end

    result = Plesk.remove_subdomain(@app.subdomain, @app.domain)
    fqdn = @app.fqdn
    @app.destroy
    notice = result.ok ? "Removed #{fqdn} (subdomain + record)." : "Removed record; Plesk said: #{result.err}"
    redirect_to root_path, notice: notice
  end

  # --- member deploy actions ---

  def deploy
    return forbidden if cannot?(:update, :apps)

    deployment = @app.deployments.create!(kind: "deploy", triggered_by: admin_email, ref: params[:ref].presence)
    enqueue(deployment)
    redirect_to app_deployment_path(@app, deployment), notice: "Deploying…"
  end

  def restart
    return forbidden if cannot?(:update, :apps)

    deployment = @app.deployments.create!(kind: "restart", triggered_by: admin_email)
    enqueue(deployment, allow_upload: false)
    redirect_to app_deployment_path(@app, deployment), notice: "Restarting…"
  end

  def migrate_primary
    return forbidden if cannot?(:update, :apps)

    deployment = @app.deployments.create!(kind: "migrate_primary", triggered_by: admin_email)
    enqueue(deployment, allow_upload: false)
    redirect_to app_deployment_path(@app, deployment), notice: "Migrating primary DB…"
  end

  def logs
    return forbidden if cannot?(:read, :apps)

    @production_log = tail(File.join(@app.app_path, "log", "production.log"))
    @error_log      = tail(File.join(@app.webspace_root, "logs", @app.fqdn, "error_log"))
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

  # Pure-Ruby tail: read the trailing slice of the file and keep the last N lines.
  def tail(path, lines: 200, bytes: 64_000)
    return "(no file at #{path})" unless File.exist?(path)

    data = File.open(path, "rb") { |f| f.seek([ 0, f.size - bytes ].max); f.read }
    data.to_s.lines.last(lines).join
  rescue StandardError => e
    "(could not read #{path}: #{e.message})"
  end

  def app_params
    params.require(:app).permit(
      :name, :app_kind, :subdomain, :domain, :ruby_version, :source_mode,
      :git_repo_url, :git_branch, :primary_db_kind, :notes,
      :deploy_path, :post_deploy_commands,
      :master_key, :env_text
    )
  end
end
