# Discovers and tails the log files the manager may show for an app. Every
# path comes from a fixed set of roots derived from the App record; a
# user-supplied file id is only ever matched against the discovered list,
# never used to build a path.
module LogFiles
  LINE_CHOICES = [ 200, 1000, 5000 ].freeze
  DEFAULT_ID   = "rails:production.log".freeze

  # Bytes read per requested line. production.log lines run long (SQL, params),
  # so budget generously — the tail still keeps only the last N lines.
  BYTES_PER_LINE = 400

  Entry = Struct.new(:id, :label, :path, :size, :mtime)

  def self.for(app)
    entries = Dir.glob(File.join(app.app_path, "log", "*.log")).sort
                 .filter_map { |p| entry("rails", p) }

    if app.rails_app?
      apache_dir = File.join(app.webspace_root, "logs", app.fqdn)
      entries += Dir.glob(File.join(apache_dir, "*")).sort
                    .reject { |p| p.end_with?(".gz", ".zip") } # rotated archives
                    .filter_map { |p| entry("apache", p) }
    end

    entries
  end

  def self.find(app, id)
    self.for(app).find { |e| e.id == id }
  end

  def self.default(app)
    entries = self.for(app)
    entries.find { |e| e.id == DEFAULT_ID } || entries.first
  end

  def self.tail(path, lines: 200)
    bytes = lines * BYTES_PER_LINE
    data = File.open(path, "rb") { |f| f.seek([ 0, f.size - bytes ].max); f.read }
    data.to_s.force_encoding(Encoding::UTF_8).scrub("?").lines.last(lines).join
  rescue StandardError => e
    "(could not read #{path}: #{e.message})"
  end

  def self.entry(kind, path)
    return nil unless File.file?(path) && File.readable?(path)

    stat = File.stat(path)
    Entry.new("#{kind}:#{File.basename(path)}", "#{kind}/#{File.basename(path)}",
              path, stat.size, stat.mtime)
  rescue StandardError
    nil
  end
end
