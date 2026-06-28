class App < ApplicationRecord
  APP_KINDS = %w[rails repo].freeze
  PRIMARY_DB_KINDS = %w[sqlite external].freeze

  has_many :deployments, -> { order(created_at: :desc) }, dependent: :destroy

  # Secrets are stored encrypted at rest (keys configured from .env in
  # config/initializers/active_record_encryption.rb).
  encrypts :master_key
  encrypts :env_text

  validates :name, presence: true
  validates :app_kind, inclusion: { in: APP_KINDS }
  validates :primary_db_kind, inclusion: { in: PRIMARY_DB_KINDS }
  validates :git_repo_url, presence: true, if: :git?

  # Rails (Plesk subdomain) apps need a subdomain/domain/ruby; repos don't.
  with_options if: :rails_app? do
    validates :subdomain, :domain, :ruby_version, presence: true
    validates :subdomain, uniqueness: { scope: :domain }
    validates :subdomain, format: { with: /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/,
                                    message: "must be a valid hostname label" }
    validates :domain, format: { with: /\A[a-z0-9.-]+\z/ }
  end

  # Repos live at a custom path and are git-only (nothing to upload-build).
  with_options if: :repo? do
    validates :deploy_path, presence: true
  end

  normalizes :subdomain, :domain, with: ->(v) { v.to_s.strip.downcase.presence }
  normalizes :deploy_path, with: ->(v) { v.to_s.strip.chomp("/").presence }

  def fqdn
    "#{subdomain}.#{domain}"
  end

  # Guard for the deploy runner. A rails app with a blank subdomain/domain makes
  # fqdn "." and app_path resolve to "/var/www/vhosts//." — inside the shared
  # webspace root, where the runner's git reset --hard would be catastrophic.
  # Validations normally prevent such a record, but a bad one (legacy, console,
  # blank import) must never reach the filesystem. Returns a reason, or nil if safe.
  def undeployable_reason
    if repo?
      "no checkout path configured" if deploy_path.blank?
    elsif subdomain.blank? || domain.blank?
      "missing subdomain or domain (resolved fqdn would be #{fqdn.inspect})"
    end
  end

  # Plesk lays every domain's files out under /var/www/vhosts/<domain>.
  def webspace_root
    "/var/www/vhosts/#{domain}"
  end

  # Where the code lives on disk: a repo's explicit checkout path, otherwise the
  # Plesk-derived subdomain folder.
  def app_path
    repo? ? deploy_path : "#{webspace_root}/#{fqdn}"
  end

  def public_path
    "#{app_path}/public"
  end

  # www-root relative to the webspace, e.g. "git.ltvb.nl/public" — what Plesk wants.
  def relative_www_root
    "#{fqdn}/public"
  end

  def rbenv_root
    "#{webspace_root}/.rbenv"
  end

  def rails_app? = app_kind == "rails"
  def repo?      = app_kind == "repo"
  def git?    = source_mode == "git"
  def external_primary? = primary_db_kind == "external"

  # Follow-up shell commands for a repo: one per non-blank, non-comment line.
  def post_deploy_command_list
    post_deploy_commands.to_s.lines.map(&:strip)
                        .reject { |l| l.empty? || l.start_with?("#") }
  end

  def last_deployment
    deployments.first
  end

  def url
    "https://#{fqdn}/"
  end
end
