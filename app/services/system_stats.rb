# Host vitals for the dashboard, read straight from /proc and one `df`.
#
# Deliberately needs no privileged call: everything here is world-readable, so
# the manager can render its own homepage without going through the agent.
#
# Parsing is split from reading (each `parse_*` takes the file's text) so the
# whole thing is testable off-server -- these files don't exist on macOS.
module SystemStats
  # CPU usage is only meaningful as a delta between two samples. /proc/stat
  # counts jiffies since boot, so a single read tells you the average since the
  # machine started -- which on an 82-day uptime is a flat, useless number.
  # Callers take two snapshots and diff them.
  CpuSample = Struct.new(:idle, :total) do
    def busy_fraction_since(previous)
      return nil if previous.nil?

      d_total = total - previous.total
      d_idle  = idle  - previous.idle
      return nil unless d_total.positive?

      ((d_total - d_idle).to_f / d_total).clamp(0.0, 1.0)
    end
  end

  module_function

  # => { load:, memory:, swap:, disk:, uptime_seconds:, cpu_count:, cpu_busy: }
  # cpu_busy is nil unless a previous CpuSample is supplied.
  def snapshot(previous_cpu: nil)
    {
      load:           parse_loadavg(read("/proc/loadavg")),
      memory:         parse_memory(read("/proc/meminfo")),
      swap:           parse_swap(read("/proc/meminfo")),
      disk:           disk_usage,
      uptime_seconds: parse_uptime(read("/proc/uptime")),
      cpu_count:      cpu_count,
      cpu_sample:     cpu_sample,
      cpu_busy:       cpu_sample&.busy_fraction_since(previous_cpu)
    }
  end

  def cpu_sample
    parse_cpu(read("/proc/stat"))
  end

  # ---- parsers (pure; take file contents) ----------------------------------

  # "0.42 0.44 0.38 2/1234 5678" => { one:, five:, fifteen: }
  def parse_loadavg(text)
    one, five, fifteen = text.to_s.split.first(3).map(&:to_f)
    return nil if one.nil?

    { one: one, five: five, fifteen: fifteen }
  end

  # MemAvailable -- NOT MemFree. On this host MemFree reads ~1.2 GB while
  # MemAvailable is ~18 GB, because the kernel counts 16 GB of reclaimable page
  # cache as "used". Reporting MemFree renders a permanent false alarm.
  def parse_memory(text)
    fields = meminfo_fields(text)
    total     = fields["MemTotal"]
    available = fields["MemAvailable"] || fields["MemFree"]
    return nil unless total&.positive? && available

    used = total - available
    { total: total, available: available, used: used,
      used_fraction: (used.to_f / total).clamp(0.0, 1.0) }
  end

  # Returns nil when no swap is configured -- the caller renders "none", not
  # "0%", which would read as healthy rather than absent.
  def parse_swap(text)
    fields = meminfo_fields(text)
    total  = fields["SwapTotal"]
    return nil unless total&.positive?

    free = fields["SwapFree"].to_i
    used = total - free
    { total: total, free: free, used: used,
      used_fraction: (used.to_f / total).clamp(0.0, 1.0) }
  end

  # meminfo is in kB; convert to bytes at the boundary so nothing downstream
  # has to remember the unit.
  def meminfo_fields(text)
    text.to_s.each_line.filter_map { |line|
      key, value = line.split(":", 2)
      next unless value

      kb = value[/\d+/]
      next unless kb

      [ key.strip, kb.to_i * 1024 ]
    }.to_h
  end

  # The aggregate "cpu" line: user nice system idle iowait irq softirq steal ...
  # idle+iowait both count as not-busy.
  def parse_cpu(text)
    line = text.to_s.each_line.find { |l| l.start_with?("cpu ") }
    return nil unless line

    values = line.split[1..].to_a.map(&:to_i)
    return nil if values.size < 5

    CpuSample.new(values[3] + values[4], values.sum)
  end

  def parse_uptime(text)
    seconds = text.to_s.split.first
    seconds && seconds.to_f.round
  end

  # `df -Pk /` => POSIX format in 1024-byte blocks. `-P` guarantees one row per
  # filesystem (an unwrapped long device name would otherwise split the line).
  # `-k` rather than GNU's `-B1`, so this also runs on BSD/macOS in development.
  BLOCK_BYTES = 1024

  def parse_disk(text)
    row = text.to_s.lines[1]
    return nil unless row

    _fs, total, used, available = row.split
    return nil unless total && used && available

    total_b = total.to_i * BLOCK_BYTES
    used_b  = used.to_i  * BLOCK_BYTES
    { total: total_b, used: used_b, available: available.to_i * BLOCK_BYTES,
      used_fraction: total_b.positive? ? (used_b.to_f / total_b).clamp(0.0, 1.0) : 0.0 }
  end

  # ---- readers -------------------------------------------------------------

  def read(path)
    File.read(path)
  rescue StandardError
    nil
  end

  # Only IO/exec failures are tolerated here. A bare `rescue StandardError`
  # would also swallow NameError, silently turning a typo into "no disk data".
  def disk_usage(path = "/")
    parse_disk(`df -Pk #{Shellwords.escape(path)} 2>/dev/null`)
  rescue SystemCallError, IOError
    nil
  end

  def cpu_count
    Etc.nprocessors
  rescue StandardError
    nil
  end

  # Exact memory for one systemd unit, no PID scanning and no privileges: the
  # cgroup file is world-readable and already accounts the whole process tree,
  # so a Puma with workers reports as one number.
  def unit_memory_bytes(unit)
    raise ArgumentError, "unsafe unit name" unless unit.to_s.match?(/\A[a-zA-Z0-9@._-]+\z/)

    value = read("/sys/fs/cgroup/system.slice/#{unit}.service/memory.current")
    value && value.strip.to_i
  end
end
