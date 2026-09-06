# Thin Ruby side of the privilege bridge, kept as a compatibility shim.
#
# Root operations used to go through /usr/local/sbin/ltvb-deployer via `sudo -n`
# — a bash wrapper with seven verbs, four of which were `plesk bin` calls that
# stopped existing when Plesk was removed. They are all served by ltvb-agentd
# now, so this translates the two verbs that still have callers and refuses the
# rest loudly rather than shelling out to a script that is no longer installed.
#
# The Result shape is unchanged, so `restart_app!` and `restart_jobs_worker!`
# did not have to change with it. Once both call the Agent directly this file,
# `Plesk`, the wrapper and its sudoers rule can all go.
module PrivilegedShell
  Result = Struct.new(:ok, :out, :err) do
    def output = [ out, err ].reject(&:blank?).join("\n")
  end

  # Legacy verb -> what the agent calls it now. `restart-app` never existed in
  # the wrapper at all: the recipe emitted it and every call came back "unknown
  # verb", which the atomic-release path logged as a warning and stepped over.
  def self.run(verb, *args)
    case verb.to_s
    when "restart-jobs"
      translate(Agent.call("jobs.restart"))
    when "restart-app"
      fqdn = args.first.to_s
      return Result.new(false, "", "restart-app needs an fqdn") if fqdn.empty?

      translate(Agent.call("systemd.restart", unit: "ltvb-app@#{fqdn}.service", action: "restart"))
    else
      Result.new(false, "", "#{verb} is not a privileged verb any more; ltvb-deployer has been retired")
    end
  rescue StandardError => e
    Result.new(false, "", "privileged call failed: #{e.message}")
  end

  def self.translate(res) = Result.new(res.ok, res.out.to_s, res.err.to_s)
end
