module ApplicationHelper
  # --- badges --------------------------------------------------------------

  # A badge carries state, so it is styled by *tone* (ok/warn/danger/neutral),
  # not by the specific word it happens to print. Adding a status means adding
  # a row here, not a colour rule in the stylesheet.
  STATUS_LABELS = {
    rails:       "live",
    redirect:    "live",
    placeholder: "placeholder!",
    error5xx:    "5xx error",
    down:        "down",
    repo:        "repo",
    unknown:     "unknown"
  }.freeze

  STATUS_TONES = {
    rails: :ok, redirect: :ok,
    placeholder: :danger, error5xx: :danger, down: :danger,
    repo: :neutral, unknown: :neutral
  }.freeze

  DEPLOYMENT_TONES = {
    "succeeded" => :ok, "deployed" => :ok,
    "failed" => :danger,
    "running" => :busy, "queued" => :busy,
    "ignored" => :neutral
  }.freeze

  CONSOLE_TONES = {
    "running" => :busy, "queued" => :busy,
    "closed" => :neutral, "failed" => :danger
  }.freeze

  # tone: :ok, :warn, :danger, :info, :neutral, or :busy (warn + pulsing dot).
  def badge(text, tone: :neutral, **attrs)
    classes = [ "badge", "badge--#{tone == :busy ? 'warn' : tone}", ("badge--busy" if tone == :busy) ]
    tag.span(text, class: classes.compact.join(" "), **attrs)
  end

  def status_badge(status)
    sym    = status.is_a?(Hash) ? status[:status] : status
    detail = status.is_a?(Hash) ? status[:detail] : nil

    badge(STATUS_LABELS[sym] || sym.to_s, tone: STATUS_TONES.fetch(sym, :neutral), title: detail)
  end

  def deployment_badge(deployment, **attrs)
    return badge("never deployed", **attrs) unless deployment

    badge(deployment.status, tone: DEPLOYMENT_TONES.fetch(deployment.status.to_s, :neutral), **attrs)
  end

  def console_badge(session, **attrs)
    label = session.status.dup
    label << " (#{session.close_reason})" if session.close_reason

    badge(label, tone: CONSOLE_TONES.fetch(session.status.to_s, :neutral), **attrs)
  end

  def exception_badge(status)
    badge(status.to_s, tone: status.to_s == "open" ? :danger : :ok)
  end

  # --- teardown ------------------------------------------------------------

  # Untracking deletes things now, so the confirmation has to name them: the
  # exact path, the workers by count, and — for the cases where the files are
  # deliberately kept — why. A dialog that says "are you sure?" is a dialog
  # nobody reads.
  def teardown_warning(app, services = [])
    lines = [ "Stop managing #{app.repo? ? app.name : app.fqdn}?", "" ]

    lines << if app.apex?
      "Its files are KEPT: #{app.app_path} is #{app.domain}'s own document root, not one app's directory."
    else
      "This DELETES #{app.app_path} and everything in it."
    end

    lines << "The Plesk subdomain is removed too." unless app.repo? || app.apex?

    if services.any?
      lines << "#{pluralize(services.size, 'worker')} (#{services.map(&:unit_name).join(', ')}) " \
               "will be stopped, disabled and forgotten."
    end

    lines << ""
    lines << "This cannot be undone."
    lines.join("\n")
  end

  # --- system vitals -------------------------------------------------------

  # Above this a resource is worth noticing; above CRITICAL it needs action.
  METER_WARN     = 0.75
  METER_CRITICAL = 0.90

  def meter_level(fraction)
    return :critical if fraction >= METER_CRITICAL
    return :warn     if fraction >= METER_WARN

    :ok
  end

  # One tile for every reading on the vitals strip, whether or not it has a
  # bar. A row of six identical boxes lines up; a mix of two shapes doesn't.
  #
  # A missing value still renders the label and detail: an unlabelled "no data"
  # tile is unreadable in a row of them, and the detail is often the whole point
  # (swap's "none configured" is a real answer, not a missing one).
  def tile(label:, value:, detail: nil, level: nil, track: nil)
    classes = [ "tile", ("tile--#{level}" if level) ].compact

    tag.div(class: classes.join(" ")) do
      safe_join([
        tag.span(label, class: "tile__label"),
        tag.span(value.presence || "—", class: "tile__value mono"),
        track,
        (tag.span(detail, class: "tile__detail") if detail)
      ].compact)
    end
  end

  # A labelled bar. The percentage is always rendered as text above it, so the
  # state is never carried by colour alone (colourblind readers, print, forced
  # -colors mode all still get the number).
  def meter(fraction, label:, detail: nil)
    pct   = fraction && (fraction * 100).round

    tile(label: label,
         value: pct ? "#{pct}%" : nil,
         detail: detail,
         level: fraction && meter_level(fraction),
         track: (tag.div(tag.i(style: "width: #{pct}%"), class: "tile__track") if pct))
  end

  def bytes_human(bytes)
    return "—" if bytes.nil?

    units = %w[B KB MB GB TB]
    value = bytes.to_f
    unit  = units.shift
    while value >= 1024 && units.any?
      value /= 1024
      unit = units.shift
    end
    format(value >= 100 || unit == "B" ? "%.0f %s" : "%.1f %s", value, unit)
  end

  def duration_human(seconds)
    return "—" if seconds.nil?

    days  = seconds / 86_400
    hours = (seconds % 86_400) / 3600
    return "#{days}d #{hours}h" if days.positive?

    "#{hours}h #{(seconds % 3600) / 60}m"
  end
end
