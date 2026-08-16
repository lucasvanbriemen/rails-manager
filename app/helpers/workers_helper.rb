module WorkersHelper
  # systemd's ActiveState vocabulary, mapped onto the badge tones. `reloading`
  # and `deactivating` are transient and read as busy for the same reason a
  # running deploy does.
  ACTIVE_STATE_TONES = {
    "active" => :ok, "failed" => :danger, "inactive" => :neutral,
    "activating" => :busy, "deactivating" => :busy, "reloading" => :busy
  }.freeze

  # A row the agent could not report on is NOT "inactive" — it is unknown, and
  # showing it as stopped would be a claim the manager cannot make. An adopted
  # worker that still runs under supervisor has no unit file at all, which
  # systemd reports as LoadState=not-found rather than an ActiveState.
  def worker_status_badge(status)
    return badge("unknown", tone: :neutral, title: "The agent could not be reached") if status.nil?

    properties = status["properties"] || {}
    return badge("no unit", tone: :neutral, title: "systemd has no unit file by that name") if properties["LoadState"] == "not-found"

    state = properties["ActiveState"].presence || "unknown"
    sub   = properties["SubState"]
    badge(state, tone: ACTIVE_STATE_TONES.fetch(state, :neutral), title: [ state, sub ].compact.join(" / "))
  end

  def worker_uptime(status)
    stamp = status&.dig("properties", "ExecMainStartTimestamp")
    return nil if stamp.blank?

    started = Time.zone.parse(stamp)
    started && "#{time_ago_in_words(started)}"
  rescue ArgumentError
    nil
  end

  def worker_memory(status)
    bytes = status&.dig("properties", "MemoryCurrent")
    # systemd reports [not set] as a 64-bit sentinel for a unit that is not
    # running; printing 16 EB would be worse than printing nothing.
    return nil if bytes.blank? || bytes.to_i <= 0 || bytes.to_i >= 2**63

    bytes_human(bytes.to_i)
  end

  def worker_restarts(status)
    count = status&.dig("properties", "NRestarts")
    count.presence && count.to_i
  end
end
