class App < ApplicationRecord
  SOURCE_MODES = %w[git upload].freeze
  PRIMARY_DB_KINDS = %w[sqlite external].freeze

  has_many :deployments, -> { order(created_at: :desc) }, dependent: :destroy

  # Secrets are stored encrypted at rest (keys configured from .env in
  # config/initializers/active_record_encryption.rb).
  encrypts :master_key
  encrypts :env_text

  validates :name, :subdomain, :domain, :ruby_version, presence: true
  validates :subdomain, uniqueness: { scope: :domain }
  validates :subdomain, format: { with: /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/,
                                  message: "must be a valid hostname label" }
  validates :domain, format: { with: /\A[a-z0-9.-]+\z/ }
  validates :source_mode, inclusion: { in: SOURCE_MODES }
  validates :primary_db_kind, inclusion: { in: PRIMARY_DB_KINDS }
  validates :git_repo_url, presence: true, if: :git?

  normalizes :subdomain, :domain, with: ->(v) { v.to_s.strip.downcase }

  def fqdn
    "#{subdomain}.#{domain}"
  end

  # Plesk lays every domain's files out under /var/www/vhosts/<domain>.
  def webspace_root
    "/var/www/vhosts/#{domain}"
  end

  def app_path
    "#{webspace_root}/#{fqdn}"
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

  def git?    = source_mode == "git"
  def upload? = source_mode == "upload"
  def external_primary? = primary_db_kind == "external"

  def last_deployment
    deployments.first
  end

  def url
    "https://#{fqdn}/"
  end
end
