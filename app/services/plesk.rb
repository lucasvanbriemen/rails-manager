# Plesk operations, all routed through the privileged wrapper. Read-only listing
# plus the three subdomain mutations the deploy recipe needs and a teardown verb.
module Plesk
  module_function

  # => [{ fqdn:, www_root: }, ...] for every domain/subdomain with hosting.
  def domains
    res = PrivilegedShell.run("list-domains")
    raise "plesk list-domains failed: #{res.output}" unless res.ok

    res.out.each_line.filter_map do |line|
      fqdn, www_root = line.chomp.split("\t", 2)
      next if fqdn.to_s.strip.empty?

      { fqdn: fqdn.strip, www_root: www_root.to_s.strip }
    end
  end

  def create_subdomain(subdomain, domain)
    PrivilegedShell.run("create-subdomain", subdomain, domain)
  end

  # relative_www_root is relative to the webspace root, e.g. "git.ltvb.nl/public".
  def set_docroot(subdomain, domain, relative_www_root)
    PrivilegedShell.run("set-docroot", subdomain, domain, relative_www_root)
  end

  def reconfigure(fqdn)
    PrivilegedShell.run("reconfigure", fqdn)
  end

  def remove_subdomain(subdomain, domain)
    PrivilegedShell.run("remove-subdomain", subdomain, domain)
  end
end
