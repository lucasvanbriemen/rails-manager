class AppsController < ApplicationController
  before_action :set_app, only: %i[show edit update destroy deploy restart migrate_primary logs]

  def index
    redirect_to root_path
  end

  def show
    @status = AppStatusChecker.check(@app)
    @deployments = @app.deployments.limit(20)
  end

  def new
    @app = App.new(ruby_version: "3.3.8", git_branch: "main", source_mode: "git", primary_db_kind: "sqlite")
  end

  def create
    @app = App.new(app_params)
    if @app.save
      deployment = @app.deployments.create!(kind: "create", triggered_by: admin_email)
      enqueue(deployment)
      redirect_to app_deployment_path(@app, deployment), notice: "Creating #{@app.fqdn}…"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @app.update(app_params)
      redirect_to @app, notice: "Saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    result = Plesk.remove_subdomain(@app.subdomain, @app.domain)
    fqdn = @app.fqdn
    @app.destroy
    notice = result.ok ? "Removed #{fqdn} (subdomain + record)." : "Removed record; Plesk said: #{result.err}"
    redirect_to root_path, notice: notice
  end

  # --- member deploy actions ---

  def deploy
    deployment = @app.deployments.create!(kind: "deploy", triggered_by: admin_email, ref: params[:ref].presence)
    enqueue(deployment)
    redirect_to app_deployment_path(@app, deployment), notice: "Deploying…"
  end

  def restart
    deployment = @app.deployments.create!(kind: "restart", triggered_by: admin_email)
    enqueue(deployment, allow_upload: false)
    redirect_to app_deployment_path(@app, deployment), notice: "Restarting…"
  end

  def migrate_primary
    deployment = @app.deployments.create!(kind: "migrate_primary", triggered_by: admin_email)
    enqueue(deployment, allow_upload: false)
    redirect_to app_deployment_path(@app, deployment), notice: "Migrating primary DB…"
  end

  def logs
    @production_log = tail(File.join(@app.app_path, "log", "production.log"))
    @error_log      = tail(File.join(@app.webspace_root, "logs", @app.fqdn, "error_log"))
  end

  # Adopt an existing Plesk subdomain into the manager.
  def import
    fqdn = params[:fqdn].to_s.strip
    subdomain, domain = fqdn.split(".", 2)
    app = App.new(name: fqdn, subdomain: subdomain, domain: domain,
                  source_mode: "upload", git_branch: "main", primary_db_kind: "sqlite",
                  ruby_version: "3.3.8")
    if app.save
      redirect_to edit_app_path(app), notice: "Imported #{fqdn} — review its settings and secrets."
    else
      redirect_to root_path, alert: "Could not import #{fqdn}: #{app.errors.full_messages.to_sentence}"
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
    tarball = save_upload if allow_upload && @app.upload? && params[:tarball].present?
    DeployJob.perform_later(deployment.id, ref: deployment.ref, upload_tarball: tarball)
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
      :name, :subdomain, :domain, :ruby_version, :source_mode,
      :git_repo_url, :git_branch, :primary_db_kind, :notes,
      :master_key, :env_text
    )
  end
end
