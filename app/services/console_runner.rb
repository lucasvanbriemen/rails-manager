require "pty"

# Runs one interactive `rails console` for a managed app inside a Solid Queue
# worker thread, bridging it to the ConsoleSession row: PTY output is appended
# to `output`, commands arrive via the `pending_input` mailbox, and a
# heartbeat lets the web tier detect a killed worker (orphan sweep).
#
#   ConsoleRunner.new(session).call
class ConsoleRunner
  POLL_INTERVAL       = 0.5  # max seconds between DB polls; PTY output wakes us sooner
  HEARTBEAT_INTERVAL  = 5.seconds
  TRIM_EVERY          = 100  # loop iterations between output trims

  def initialize(session)
    @session = session
    @app     = session.app
    @carry   = "".b   # bytes of a UTF-8 char split across PTY reads
  end

  def call
    @session.update!(status: "running", started_at: Time.current,
                     heartbeat_at: Time.current)
    @last_activity = Time.current

    Bundler.with_unbundled_env do
      # PTY.spawn forwards to Process.spawn, so the env hash + chdir: work.
      reader, writer, pid = PTY.spawn(console_env, "bundle", "exec", "rails",
                                      "console", "-e", "production",
                                      chdir: @app.app_path)
      begin
        reason = run_loop(reader, writer, pid)
        terminate(writer, pid)
        @session.finish!(reason)
      rescue StandardError
        terminate(writer, pid)
        raise
      end
    end
    @session.trim_output!
  rescue StandardError => e
    @session.append_output("\n== console error: #{e.class}: #{e.message} ==\n")
    @session.update!(status: "failed", closed_at: Time.current, pending_input: nil)
  end

  private

  def run_loop(reader, writer, pid)
    iterations = 0
    loop do
      return "exited" unless drain(reader)
      return "exited" if PTY.check(pid)

      heartbeat!
      close_requested, command = ConsoleSession.where(id: @session.id)
                                               .pick(:close_requested, :pending_input)
      return "requested" if close_requested

      if command
        # Read-then-clear is safe: submit_input's CAS only writes while the
        # mailbox is nil, and it stays non-nil until this clear.
        ConsoleSession.where(id: @session.id).update_all(pending_input: nil)
        writer.write(command.delete("\r") + "\n")
        touch_activity
      end

      return "idle_timeout" if Time.current - @last_activity > ConsoleSession::IDLE_TIMEOUT

      # Wakes immediately on new PTY output, else settles at DB-poll cadence.
      IO.select([ reader ], nil, nil, POLL_INTERVAL)

      @session.trim_output! if ((iterations += 1) % TRIM_EVERY).zero?
    end
  end

  # Pull everything currently buffered on the PTY into the transcript.
  # Returns false once the console process has closed its end.
  def drain(reader)
    loop do
      chunk = reader.read_nonblock(4096, exception: false)
      return true if chunk == :wait_readable
      return false if chunk.nil? # EOF

      @session.append_output(sanitize(chunk))
      touch_activity
    end
  rescue Errno::EIO # Linux PTY: slave side closed
    false
  end

  def terminate(writer, pid)
    begin
      writer.write("exit\n")
    rescue StandardError
      nil
    end
    8.times do # ~2s grace for a clean exit
      return reap(pid) if PTY.check(pid)

      sleep 0.25
    end
    Process.kill("TERM", pid)
    sleep 1
    Process.kill("KILL", pid) unless PTY.check(pid)
    reap(pid)
  rescue Errno::ESRCH
    reap(pid)
  end

  def reap(pid)
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end

  # The app's normal shell env (real credentials, no dummy secret) plus
  # everything that keeps IRB scrapeable through a dumb terminal: TERM=dumb
  # switches Reline to plain line IO (no redraws/autocomplete rendering),
  # and $IRBRC points at our rc so a stray ~/.irbrc in the webspace can't
  # re-enable any of it.
  def console_env
    AppShellEnv.rails(@app,
                      "TERM"                => "dumb",
                      "NO_COLOR"            => "1",
                      "IRB_USE_AUTOCOMPLETE" => "false",
                      "PAGER"               => "cat",
                      "IRBRC"               => Rails.root.join("config/console_session.irbrc").to_s)
  end

  # PTY output can split a UTF-8 char across reads and may carry ANSI escapes
  # from app code (TERM=dumb suppresses IRB's own). Carry incomplete trailing
  # bytes to the next read, scrub what's genuinely invalid, strip CSI/OSC
  # sequences, and drop \r so the <pre> doesn't double-space.
  def sanitize(chunk)
    bytes = @carry + chunk.b
    @carry = "".b
    text = bytes.force_encoding(Encoding::UTF_8)

    unless text.valid_encoding?
      tail = incomplete_tail(bytes)
      if tail.positive?
        @carry = bytes[-tail..].b
        text = bytes[0...-tail].force_encoding(Encoding::UTF_8)
      end
      text = text.scrub("?")
    end

    text.gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, "") # CSI
        .gsub(/\e\][^\a\e]*(\a|\e\\)?/, "")   # OSC
        .delete("\r")
  end

  # Number of trailing bytes that look like the start of an unfinished UTF-8
  # sequence (a lead byte with too few continuation bytes after it).
  def incomplete_tail(bytes)
    (1..3).each do |n|
      break if n > bytes.bytesize

      lead = bytes.getbyte(-n)
      return 0 if lead < 0x80                  # ASCII — nothing unfinished
      next if lead < 0xC0                      # continuation byte, look further back

      expected = if lead >= 0xF0 then 4
      elsif lead >= 0xE0 then 3
      else 2
      end
      return expected > n ? n : 0
    end
    0
  end

  def touch_activity
    @last_activity = Time.current
    if @activity_written_at.nil? || Time.current - @activity_written_at > 2
      @activity_written_at = Time.current
      ConsoleSession.where(id: @session.id).update_all(last_activity_at: Time.current)
    end
  end

  def heartbeat!
    return if @heartbeat_at && Time.current - @heartbeat_at < ConsoleRunner::HEARTBEAT_INTERVAL

    @heartbeat_at = Time.current
    ConsoleSession.where(id: @session.id).update_all(heartbeat_at: Time.current)
  end
end
