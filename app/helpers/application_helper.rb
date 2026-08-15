module ApplicationHelper
  STATUS_LABELS = {
    rails:       "Live",
    redirect:    "Live",
    placeholder: "Placeholder!",
    error5xx:    "5xx error",
    down:        "Down",
    repo:        "Repo",
    unknown:     "Unknown"
  }.freeze

  def status_badge(status)
    sym = status.is_a?(Hash) ? status[:status] : status
    label = STATUS_LABELS[sym] || sym.to_s
    title = status.is_a?(Hash) ? status[:detail] : nil
    tag.span(label, class: "badge badge--#{sym}", title: title)
  end

  def deployment_badge(deployment)
    return tag.span("—", class: "badge") unless deployment

    tag.span(deployment.status, class: "badge badge--dep-#{deployment.status}")
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

  # A labelled bar. The percentage is always rendered as text beside it, so the
  # state is never carried by colour alone (colourblind readers, print, forced
  # -colors mode all still get the number).
  #
  # A nil fraction still renders the label and detail: an unlabelled "no data"
  # tile is unreadable in a row of them, and the detail is often the whole point
  # (swap's "none configured" is a real answer, not a missing one).
  def meter(fraction, label:, detail: nil)
    pct     = fraction && (fraction * 100).round
    classes = [ "meter", ("meter--#{meter_level(fraction)}" if fraction) ].compact

    tag.div(class: classes.join(" ")) do
      safe_join([
        tag.div(class: "meter__head") do
          safe_join([ tag.span(label, class: "meter__label"),
                      tag.span(pct ? "#{pct}%" : "—", class: "meter__value") ])
        end,
        (tag.div(tag.i(style: "width: #{pct}%"), class: "meter__track") if pct),
        (tag.div(detail, class: "meter__detail") if detail)
      ].compact)
    end
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
