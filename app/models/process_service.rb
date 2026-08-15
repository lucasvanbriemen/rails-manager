require "shellwords"

# A long-running background process the manager knows about: a Solid Queue
# worker, the standalone ActionCable Puma, a Laravel queue worker, the Kokoro
# TTS server. Seven of these exist today — three as hand-written systemd units
# and four as supervisor programs — and this table is what lets all seven be
# described, rendered and eventually run the same way once supervisor is gone.
#
# The command is an argv ARRAY, never a command string. supervisor's `command=`
# is a string it splits itself, so every value in it is one quoting bug away
# from being a second command; a systemd ExecStart built from a validated array
# has no shell in it at all. Nothing in this model accepts a string command, not
# even as a convenience.
#
# `managed: false` means adopted-but-not-owned: the row describes something that
# is already running and configured elsewhere, so the manager may show it but
# must not write its unit file. Every row created by the migration starts that
# way — describing the seven workers is safe, rewriting them mid-migration is
# not.
class ProcessService < ApplicationRecord
  # solid_queue  — `bundle exec rails solid_queue:start` / `bin/jobs`
  # cable        — a standalone Puma serving only /cable
  # laravel_queue— `php artisan queue:work`
  # python       — a venv interpreter running a long-lived script (Kokoro TTS)
  # generic      — anything else; still argv, still validated
  KINDS = %w[solid_queue cable laravel_queue python generic].freeze

  # Optional: the ActionCable server belongs to git.ltvb.nl, but a future
  # host-wide worker would belong to no app at all.
  belongs_to :app, optional: true

  # The name IS the systemd unit name, so it has to be usable as one before it
  # is stored — not sanitised later, when a caller might already have built a
  # path out of it.
  normalizes :name, with: ->(v) { v.to_s.strip.downcase.presence }

  validates :name, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :user, presence: true
  validates :working_directory, presence: true

  # All five checks below delegate to SystemdUnit, which is the code that
  # actually renders the file root executes. Duplicating its patterns here would
  # let the two drift, and the looser of the two would be the one that matters.
  validate :name_is_a_safe_unit_name
  validate :user_is_safe
  validate :working_directory_is_safe
  validate :argv_is_safe
  validate :environment_is_safe

  scope :managed,  -> { where(managed: true) }
  scope :adopted,  -> { where(managed: false) }
  scope :active,   -> { where(enabled: true) }
  scope :ordered,  -> { order(:name) }

  # Adopted rows describe reality; the manager renders them but must not install
  # over the hand-written unit or supervisor program that owns them today.
  def adopted? = !managed?

  # The manager will only write and start a unit that it both owns and is
  # supposed to be running.
  def installable? = managed? && enabled?

  def unit_name = "#{name}.service"
  def unit_path = SystemdUnit.service_unit_path(self)

  def render_unit(**options) = SystemdUnit.render_service(self, **options)

  def argv_list = argv.is_a?(Array) ? argv : []

  # Description= is one line. Operators put the real explanation in notes, so
  # lead with that and fall back to something that at least identifies the row.
  def description_line
    notes.to_s.lines.map(&:strip).find(&:present?) || "#{name} (#{kind}) — managed by apps.ltvb.nl"
  end

  # For display and for copy-pasting into a shell to reproduce a failure. It is
  # NOT how the process is started — argv_list is, and it never passes through a
  # shell. Shellwords rather than join(" ") so what is shown is unambiguous even
  # when an argument contains a space.
  def command_preview
    Shellwords.join(argv_list)
  rescue StandardError
    argv.inspect
  end

  private

  def name_is_a_safe_unit_name
    return if name.blank?

    SystemdUnit.unit_name!(name)
  rescue SystemdUnit::Unsafe => e
    errors.add(:name, e.message)
  end

  def user_is_safe
    return if user.blank?

    SystemdUnit.unix_name!(user)
  rescue SystemdUnit::Unsafe => e
    errors.add(:user, e.message)
  end

  def working_directory_is_safe
    return if working_directory.blank?

    SystemdUnit.absolute_path!(working_directory)
  rescue SystemdUnit::Unsafe => e
    errors.add(:working_directory, e.message)
  end

  def argv_is_safe
    SystemdUnit.argv!(argv)
  rescue SystemdUnit::Unsafe => e
    errors.add(:argv, e.message)
  end

  # Not coerced with `|| {}`: the column defaults to {} on new records, so an
  # actual nil means someone cleared it, and the renderer would raise on it
  # later anyway — better to say so while the record is still being edited.
  def environment_is_safe
    SystemdUnit.environment!(environment)
  rescue SystemdUnit::Unsafe => e
    errors.add(:environment, e.message)
  end
end
