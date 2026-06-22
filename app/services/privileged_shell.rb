require "open3"

# Thin Ruby side of the privilege bridge. Every root operation goes through the
# single vetted wrapper at /usr/local/sbin/ltvb-deployer via `sudo -n` (no
# password). Arguments are passed as a real argv array — never interpolated into
# a shell — so the wrapper receives them verbatim and does the validation.
module PrivilegedShell
  SCRIPT = "/usr/local/sbin/ltvb-deployer".freeze

  Result = Struct.new(:ok, :out, :err) do
    def output = [ out, err ].reject(&:blank?).join("\n")
  end

  def self.run(verb, *args)
    out, err, status = Open3.capture3("sudo", "-n", SCRIPT, verb.to_s, *args.map(&:to_s))
    Result.new(status.success?, out, err)
  rescue StandardError => e
    Result.new(false, "", "privileged call failed: #{e.message}")
  end
end
