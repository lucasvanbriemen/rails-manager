require "shellwords"

# One crontab line, described. Nine exist on this server across five users, and
# until this table they were invisible to the manager: three apps
# (ai.ltvb.nl, calendar. and email.lucasvanbriemen.nl) have no vhost at all and
# run *only* because of one, and root's every-minute deploy watcher is the most
# privileged process on the box.
#
# Two rules, both inherited from ProcessService for the same reasons:
#
#   1. The command is an argv ARRAY, never a command string. cron hands its line
#      to a shell, which is exactly the property that makes a stored value one
#      quoting bug away from being a second command; a systemd ExecStart built
#      from a validated array has no shell in it to escape from. `cd <dir> && …`
#      and `>> /dev/null 2>&1` are shell constructs and are columns, not argv.
#
#   2. `managed: false` means adopted-but-not-owned: the row describes a line
#      cron still owns, and the manager may show it but must not rewrite it.
#      Every row the migration creates starts that way.
#
# Adopted rows are held to a deliberately looser standard than managed ones,
# because their job is to be *true*. Two real lines start with a bare `php` /
# `python3` that cron resolves from PATH, and one runs as root. Refusing to
# record those would not make them stop running — it would only make them
# invisible again. #promotion_blockers is where that difference becomes
# actionable.
class ScheduledJob < ApplicationRecord
  # cron's own shorthands. @reboot is in the list because cron accepts it, not
  # because anything here uses it — a row that lied about the schedule would be
  # worse than no row.
  MACROS = %w[@reboot @yearly @annually @monthly @weekly @daily @midnight @hourly].freeze

  # One cron field: numbers, names (JAN, mon-fri), ranges, steps and lists.
  # Narrower than cron itself accepts, because a managed row's schedule is
  # written into a file root parses.
  CRON_FIELD = %r{\A[0-9A-Za-z*,\-/]+\z}

  # A command name with no directory in it, which cron looks up in PATH and
  # systemd cannot. Anchored so nothing with a slash, a space or a control
  # character can be mistaken for one.
  BARE_COMMAND = /\A[A-Za-z0-9][A-Za-z0-9._+-]*\z/

  # Binaries that live inside Plesk. Every one of them disappears when Plesk is
  # removed, which is the single most likely way one of these jobs dies quietly.
  PLESK_PREFIXES = %w[/opt/psa/ /usr/local/psa/].freeze

  ROOT = "root".freeze

  # Optional: root's deploy watcher belongs to the host, and rijschool's python
  # scripts run against an app they are not installed in.
  belongs_to :app, optional: true

  # The name is ours, not the server's — cron lines have no identity. It becomes
  # a unit/timer name, so it has to be usable as one before it is stored.
  normalizes :name, with: ->(v) { v.to_s.strip.downcase.presence }
  # Tab-separated in every real crontab here; stored space-separated so two rows
  # describing the same schedule compare equal.
  normalizes :cron_schedule, with: ->(v) { v.to_s.split(/\s+/).join(" ").presence }
  normalizes :user, with: ->(v) { v.to_s.strip.presence }
  normalizes :working_directory, with: ->(v) { v.to_s.strip.chomp("/").presence }

  validates :name, presence: true, uniqueness: true
  validates :user, presence: true
  validates :cron_schedule, presence: true

  validate :name_is_a_safe_unit_name
  validate :cron_schedule_is_well_formed
  validate :user_is_safe
  validate :working_directory_is_safe
  validate :argv_is_safe
  validate :environment_is_safe

  scope :managed, -> { where(managed: true) }
  scope :adopted, -> { where(managed: false) }
  scope :active,  -> { where(enabled: true) }
  scope :ordered, -> { order(:user, :name) }

  # Two rows describe the same crontab line when the user, the schedule and the
  # argv match. The name cannot be part of it: cron has no names, so ours is
  # derived, and a derivation that changes must not turn one job into two.
  def self.signature_for(user:, cron_schedule:, argv:)
    [ user.to_s, cron_schedule.to_s.split(/\s+/).join(" "), Array(argv).map(&:to_s) ]
  end

  def signature = self.class.signature_for(user: user, cron_schedule: cron_schedule, argv: argv_list)

  def adopted? = !managed?

  # The manager will only install a timer it both owns and is supposed to run.
  def installable? = managed? && enabled?

  def argv_list = argv.is_a?(Array) ? argv : []

  def runs_as_root? = user == ROOT

  # systemd resolves the binary itself and has no PATH to search; cron does.
  def command_resolved? = argv_list.first.to_s.start_with?("/")

  def plesk_dependent?
    PLESK_PREFIXES.any? { |prefix| argv_list.first.to_s.start_with?(prefix) }
  end

  # What stops this row being flipped to managed: true and handed to systemd.
  # Facts about the crontab line, not policy — the list is empty for a job that
  # is ready and non-empty for one that is not, so nothing has to be remembered
  # at promotion time.
  def promotion_blockers
    blockers = []
    unless command_resolved?
      blockers << "argv[0] is the bare command #{argv_list.first.to_s.inspect}; cron resolves it " \
                  "from PATH and systemd will not"
    end
    blockers << "runs as root, which the unit renderer refuses outright" if runs_as_root?
    if plesk_dependent?
      blockers << "runs #{argv_list.first}, a Plesk binary that disappears when Plesk does"
    end
    blockers
  end

  # For display and for pasting into a shell to reproduce a failure. It is NOT
  # how the job is run — argv_list is, and that never passes through a shell.
  def command_preview
    Shellwords.join(argv_list)
  rescue StandardError
    argv.inspect
  end

  # The line as cron sees it, rebuilt from the columns. Display only, and the
  # round trip is the point: if this does not match the crontab, the row is
  # describing something other than what is running.
  def crontab_line
    command = command_preview
    command = "cd #{Shellwords.escape(working_directory)} && #{command}" if working_directory.present?
    command = "#{command} >> /dev/null 2>&1" if discard_output?
    "#{cron_schedule} #{command}"
  end

  # Description= is one line; the operator's explanation beats a generated one.
  def description_line
    notes.to_s.lines.map(&:strip).find(&:present?) || "#{name} (#{cron_schedule}) — managed by apps.ltvb.nl"
  end

  private

  def name_is_a_safe_unit_name
    return if name.blank?

    SystemdUnit.unit_name!(name)
  rescue SystemdUnit::Unsafe => e
    errors.add(:name, e.message)
  end

  def cron_schedule_is_well_formed
    return if cron_schedule.blank?
    return if MACROS.include?(cron_schedule)

    fields = cron_schedule.split(" ")
    if fields.size != 5
      errors.add(:cron_schedule, "must be five cron fields or one of #{MACROS.join(', ')}")
      return
    end

    bad = fields.reject { |field| field.match?(CRON_FIELD) }
    errors.add(:cron_schedule, "has fields that are not cron expressions: #{bad.join(' ')}") if bad.any?
  end

  # SystemdUnit refuses `root` outright because it renders units root executes.
  # An adopted row is not rendered, and root is a real cron user here — so only
  # the shape of the name is checked for those, and promotion_blockers carries
  # the rest.
  def user_is_safe
    return if user.blank?
    return SystemdUnit.unix_name!(user) if managed?
    return if user.match?(SystemdUnit::USERNAME)

    errors.add(:user, "is not a valid unix user name")
  rescue SystemdUnit::Unsafe => e
    errors.add(:user, e.message)
  end

  def working_directory_is_safe
    return if working_directory.blank?

    SystemdUnit.absolute_path!(working_directory)
  rescue SystemdUnit::Unsafe => e
    errors.add(:working_directory, e.message)
  end

  # SystemdUnit.argv! is the single source of truth for what may reach a unit
  # file, so every element goes through it — blank, control character, bare `;`,
  # array-not-string. Only the absolute-argv[0] rule is relaxed, and only for an
  # adopted row, by checking a stand-in that names where the binary actually is.
  def argv_is_safe
    SystemdUnit.argv!(argv_for_check)
  rescue SystemdUnit::Unsafe => e
    errors.add(:argv, e.message)
  end

  def argv_for_check
    first = argv.is_a?(Array) ? argv.first : nil
    return argv unless adopted? && first.is_a?(String) && first.match?(BARE_COMMAND)

    [ "/usr/bin/#{first}", *argv.drop(1) ]
  end

  # Not coerced with `|| {}`: the column defaults to {}, so a nil means someone
  # cleared it and the renderer would raise on it later anyway.
  def environment_is_safe
    SystemdUnit.environment!(environment)
  rescue SystemdUnit::Unsafe => e
    errors.add(:environment, e.message)
  end
end
