require "json"
require "securerandom"
require "socket"

# Client for ltvb-agentd, the root daemon on /run/ltvb-agent.sock. Replaces
# PrivilegedShell (sudo + a bash wrapper) and returns the same Result shape, so
# call sites can be moved over one at a time rather than in one commit.
#
# Two things this file deliberately does NOT do:
#
#   * It does not know the schema. Parameters are validated by the agent, as
#     root, against the agent's own copy — a client-side check would only ever
#     be a duplicate that drifts, and the one that matters is the one the
#     privileged side runs.
#   * It does not build paths. Every verb takes an fqdn; the agent decides which
#     directory that means. Sending a path from here would put the web user back
#     in charge of what root writes to.
#
# The same rule covers config text, and it is worth stating because the obvious
# design is the wrong one: `nginx.site.write` takes a RENDER SPEC — a kind from
# a closed enum, a document-root suffix, a handful of booleans, a list of CIDRs
# — and never the rendered file. Root renders from its own templates. A verb
# that accepted config text would make this file, running as a uid eight
# internet-facing apps share, the author of what nginx and systemd parse.
module Agent
  # Overridable for a development box that has no agent, never in production.
  SOCKET_PATH = ENV.fetch("LTVB_AGENT_SOCKET", "/run/ltvb-agent.sock").freeze

  # Must match ltvb-agentd's PROTOCOL. Duplicated on purpose: the agent is
  # installed by root and is NEVER updated by an app deploy, so a deploy of this
  # checkout can absolutely leave the two out of step. When it does, every call
  # fails loudly with "protocol mismatch" instead of quietly sending a request
  # the other side reads differently.
  PROTOCOL = 1

  # The agent caps a request line at 1 MiB and drops the connection over it.
  # Refusing here first turns a truncated, confusing failure into a clear one.
  MAX_REQUEST_BYTES = 512 * 1024

  # Ceiling on a single response line. sites.discover over 22 hosts is a few
  # tens of KB; anything approaching this is a bug on the other side.
  MAX_RESPONSE_BYTES = 8 * 1024 * 1024

  # Long enough for `plesk bin subdomain --create`, which really does take
  # minutes on this box. The agent enforces its own per-verb deadline and kills
  # the process group; this is only the client giving up on the socket.
  DEFAULT_TIMEOUT = 600

  # A successful handshake is cached briefly rather than forever: Passenger
  # processes live for days, and an agent upgraded underneath one must not need
  # a web restart to be noticed. Failures are never cached — a down agent that
  # comes back should work on the next call.
  HANDSHAKE_TTL = 60

  # Same positional members as PrivilegedShell::Result, plus what the socket can
  # carry and a pipe could not: structured data and a machine-readable code.
  Result = Struct.new(:ok, :out, :err, :data, :code) do
    def output = [ out, err ].reject(&:blank?).join("\n")
  end

  class << self
    # Agent.call("http.check", fqdn: "git.ltvb.nl") => Result
    #
    # Never raises. A dead agent, a protocol mismatch and a rejected parameter
    # all come back as Result#ok == false, because every caller is inside a
    # deploy job that wants to log the reason and carry on deciding what to do.
    def call(verb, timeout: DEFAULT_TIMEOUT, **params)
      handshake = negotiate
      return handshake unless handshake.ok
      # Array(): "never raises" is this method's whole contract, and an agent
      # that answered the handshake without a verb list would otherwise take a
      # NoMethodError straight out through it. No list means no verbs.
      unless Array(handshake.data["verbs"]).include?(verb.to_s)
        return failure("agent #{handshake.data['agent_version']} does not implement #{verb}", "unknown_verb")
      end

      request(verb, params, timeout)
    end

    # The handshake itself, uncached — for a health check that should reflect
    # the agent's state now rather than up to a minute ago.
    def ping(timeout: 10)
      request("ping", {}, timeout)
    end

    def available? = negotiate.ok

    # A method rather than a bare constant reference so the protocol itself can
    # be tested against a throwaway socket. Production has exactly one value.
    def socket_path = SOCKET_PATH

    # The agent's verb list, or [] when it cannot be reached. Lets the manager
    # render "this needs a newer agent" instead of offering a button that fails.
    def verbs
      result = negotiate
      result.ok ? result.data["verbs"] : []
    end

    # Drops the cached handshake. For tests and for the console after a
    # `systemctl restart ltvb-agent`.
    def reset!
      @handshake = nil
      @handshake_at = nil
    end

    private

    def negotiate
      return @handshake if @handshake && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @handshake_at < HANDSHAKE_TTL

      result = ping
      return result unless result.ok

      protocol = result.data && result.data["protocol"]
      unless protocol == PROTOCOL
        # Refuse rather than guess. The agent runs as root; a client that thinks
        # it understands a contract it does not is how a parameter ends up
        # meaning something else on the privileged side.
        return failure("agent speaks protocol #{protocol.inspect}, this manager speaks #{PROTOCOL} — " \
                       "reinstall /usr/local/sbin/ltvb-agentd as root", "protocol")
      end

      @handshake_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @handshake = result
    end

    def request(verb, params, timeout)
      line = JSON.generate("id" => SecureRandom.hex(8), "verb" => verb.to_s, "params" => params.transform_keys(&:to_s))
      return failure("request is #{line.bytesize} bytes, over the #{MAX_REQUEST_BYTES} byte limit", "oversize") if line.bytesize > MAX_REQUEST_BYTES

      # One connection per call. The agent answers one connection at a time, and
      # a pooled socket shared between Passenger threads would need locking to
      # keep two replies from being read by the wrong caller — for a call that
      # happens a few times per deploy.
      socket = UNIXSocket.new(socket_path)
      begin
        socket.write("#{line}\n")
        parse(read_line(socket, timeout))
      ensure
        socket.close
      end
    rescue Errno::ENOENT
      failure("agent socket #{socket_path} does not exist — is ltvb-agent running?", "unavailable")
    rescue Errno::EACCES
      failure("permission denied on #{socket_path} — this process's uid is not allowed to call the agent", "denied")
    rescue Errno::ECONNREFUSED
      failure("agent socket exists but nothing is listening — `systemctl status ltvb-agent`", "unavailable")
    rescue JSON::ParserError => e
      failure("agent sent malformed JSON: #{e.message}", "protocol")
    rescue StandardError => e
      failure("agent call failed: #{e.class}: #{e.message}", "unavailable")
    end

    # IO#gets with a limit, plus a wall-clock deadline. Net::HTTP-style timeouts
    # are not available on a raw UNIXSocket, and a blocking read against a wedged
    # root daemon would hang a Solid Queue worker indefinitely.
    def read_line(socket, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      buffer = +""

      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise IO::TimeoutError, "no response within #{timeout}s" if remaining <= 0
        raise IO::TimeoutError, "no response within #{timeout}s" unless socket.wait_readable(remaining)

        chunk = socket.read_nonblock(64 * 1024, exception: false)
        raise EOFError, "agent closed the connection without replying" if chunk.nil?
        next if chunk == :wait_readable

        buffer << chunk
        raise IOError, "response exceeds #{MAX_RESPONSE_BYTES} bytes" if buffer.bytesize > MAX_RESPONSE_BYTES

        index = buffer.index("\n")
        return buffer[0, index] if index
      end
    end

    def parse(line)
      payload = JSON.parse(line)
      Result.new(payload["ok"] == true, payload["out"].to_s, payload["err"].to_s,
                 payload["data"], payload["code"])
    end

    def failure(message, code)
      Result.new(false, "", message, nil, code)
    end
  end
end
