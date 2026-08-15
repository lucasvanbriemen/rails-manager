# ltvb-agentd

The root privilege boundary for the apps.ltvb.nl manager. Replaces
`sudo -n /usr/local/sbin/ltvb-deployer` (137 lines of bash, 7 verbs) with 26
schema-validated ones.

The manager web app runs unprivileged. Everything it needs root for — creating a
vhost, writing a systemd unit, regenerating a postfix map, issuing a certificate
— goes through a request on `/run/ltvb-agent.sock` to a root daemon that
validates it against a declarative schema before anything runs.

## Why not keep the bash wrapper

Replacing Plesk needs roughly 45 verbs, not 7. At that size a bash script is a
root shell with extra steps: one unquoted expansion, one `$(…)` reaching a value
that came from a web form, and the boundary is gone. The failure mode is silent
and total.

The daemon makes the dangerous things structurally impossible rather than
individually guarded:

| Risk | How bash handled it | How the agent handles it |
|---|---|---|
| Argument injection | per-call `[[ =~ ]]` a developer must remember | one declarative schema; a verb cannot run without it |
| Extra/unexpected arguments | ignored | hard error |
| Path traversal | `[[ "$p" != *".."* ]]` | no path is ever a parameter |
| Hostile config text | not attempted | templates are root-owned, named by the handler |
| Caller identity | `sudo`, so any process running as `ltvb` | `SO_PEERCRED`, a dedicated uid |
| A broken config going live | not attempted | stage → validate → rename → reload → roll back |
| Forensics | none | one JSON audit line per call |

## Security model

1. **`SO_PEERCRED`, not file permissions.** The socket is `0660 root:ltvb-agent`,
   but that is only the outer door. The kernel reports the connecting process's
   uid and the agent checks it against `allowed_users`. This matters here
   specifically: six internet-facing apps run as the `ltvb` uid today, so
   "member of the group" and "is the manager" are not the same statement. The
   manager gets its own account.

2. **No path is ever a parameter.** The client sends `fqdn: "git.ltvb.nl"`. The
   agent looks `ltvb.nl` up in its own webspace table and derives
   `/var/www/vhosts/ltvb.nl/git.ltvb.nl`. There is no `..` check in the codebase
   because there is nothing to check — a traversal would have to come out of a
   root-owned JSON file. Even the document root is composed agent-side: the
   client sends `suffix: "public"`, not `"git.ltvb.nl/public"`.

3. **No config text from the web app.** `nginx.site.write` takes a *render
   spec* — a kind from a closed enum, a document-root suffix, a handful of
   booleans, a list of CIDRs — and never a line of nginx config. Root renders
   from templates that live in `/etc/ltvb/agent/templates`, are named by a
   constant in the handler (never by a request), and are refused unless they are
   plain root-owned non-writable files. A symlink there is treated as an attack,
   not a convenience. Every template also has a copy compiled into the daemon,
   so a box with an empty template directory still serves sites; an installed
   file overrides it, an installed file that fails the trust check is fatal.

   **This rule covers the manager's own renderers too.** `NginxConfig` and
   `SystemdUnit` used to read `Rails.root.join("deploy/templates/…")`. That path
   is inside the checkout, owned by uid 10006 — the uid **eight** internet-facing
   apps share — so an RCE in any one of them rewrote a template that root then
   rendered into a systemd unit or an nginx config. Both now read
   `/etc/ltvb/agent/templates` and `/etc/ltvb/agent/templates/systemd` through
   the same lstat check (regular file, uid 0, not group- or other-writable), and
   fall back to the checkout **only** under `Rails.env.development?` /
   `Rails.env.test?`. A production box missing the installed directory raises;
   it does not fall back.

   **And there is now one nginx template, not two.** `NginxConfig` used to own a
   parallel set under `deploy/templates/nginx/*.conf.erb` that only it read,
   while this daemon rendered its own built-in ERB to write the file nginx
   actually serves. They drifted: the index-precedence fix was applied to the
   manager's copy and changed nothing that was served, and on the box itself
   `admin.` and `login.rijschool-mos.nl` kept `index index.php index.html` while
   `student.` — the one site re-rendered afterwards — carried the fix. The
   daemon's renderer survived, because it is the one that renders root-side from
   a root-owned template; `NginxConfig` now renders that same file with that same
   variable set, so a failing manager test means the served config is wrong.
   `deploy/agent/embed-nginx-template` regenerates the daemon's built-in copy
   from the authored file, and the suite fails if the two differ.

4. **Two-phase writes, reload never restart.** `<path>.new` is created with
   `O_EXCL|O_NOFOLLOW`, handed to a validator, backed up to `<path>.bak`,
   renamed into place, and then reloaded. A reload that refuses the file puts
   the old one back and reloads again; if *that* fails too, the call raises
   `broken` and leaves `.bak` for a human. A restart would drop every live
   connection to twenty-two sites to fix one of them.

   The `.bak` is opened `O_NOFOLLOW` with **the same mode as the file it
   copies**, and is unlinked as soon as the reload succeeds. It only ever
   existed for the rollback path: the first file this mechanism protects is
   `ltvb-app@login.ltvb.nl.service`, whose `Environment=` line is the only copy
   of that app's `RAILS_MASTER_KEY` on the box, and a `File.binwrite` backup
   under the default umask is 0644 — which hands it to all eight.
   `nginx.site.remove` and `systemd.unit.remove` use the same contract in
   reverse, so a removal that breaks the config is put back too.

5. **Audit log.** `/var/log/ltvb-agent/audit.log`, one JSON line per call, mode
   0600. Mutating verbs are logged before the work starts as well as after, so a
   call that wedges the machine still left a record of what it was attempting.
   Parameters declared `secret: true` are recorded as
   `{"param":"env_text","sha256":"…","bytes":231}` — enough to answer "was that
   the key we stored?" without the log becoming a second copy of every secret on
   the box.

6. **The agent is never updated by an app deploy.** It is installed by root,
   deliberately. The manager can rewrite its own checkout; an agent that
   checkout could replace would be ornamental.

## Install

As root, on server.ltvb.nl. Nothing below is run by a deploy.

```sh
# 1. Accounts. The manager stops sharing the `ltvb` uid with six public apps.
adduser --system --group --home /var/www/vhosts/ltvb.nl --shell /usr/sbin/nologin ltvb-manager
groupadd -f ltvb-agent
usermod -a -G ltvb-agent ltvb-manager

# 2. Config, root-owned and not group-writable or the agent refuses to start.
install -o root -g root -m 0755 -d /etc/ltvb/agent /etc/ltvb/agent/templates
cat > /etc/ltvb/agent/agent.json <<'JSON'
{ "allowed_users": ["ltvb-manager"], "socket_group": "ltvb-agent" }
JSON
chmod 0644 /etc/ltvb/agent/agent.json

# 3. The webspace table — the ONLY source of on-disk paths. `manageable` is what
#    the bash wrapper spelled ALLOWED_DOMAINS: mutating verbs are refused
#    anywhere it is false. The four customer webspaces stay read-only.
cat > /etc/ltvb/agent/webspaces.json <<'JSON'
{
  "ltvb.nl":                 { "owner": "ltvb",                            "manageable": true  },
  "lucasvanbriemen.nl":      { "owner": "lucasvanbriemen.nl_p8c08835y9j",  "manageable": true  },
  "djtim.eu":                { "owner": "djtim.eu_aqwzxapl85w",            "manageable": false },
  "rijschool-mos.nl":        { "owner": "rijschool-mos.nl_gze6m7rrghq",    "manageable": false },
  "voordezorgmanagement.nl": { "owner": "voordezorgmanagement._rhc4zy0iyc", "manageable": false },
  "mos-safeguards.com":      { "owner": "mos-safeguards.com_eea0inbcx8t",  "manageable": false }
}
JSON
chmod 0644 /etc/ltvb/agent/webspaces.json

# 4. The daemon and its unit.
install -o root -g root -m 0700 deploy/agent/ltvb-agentd /usr/local/sbin/ltvb-agentd
install -o root -g root -m 0644 deploy/agent/ltvb-agent.service /etc/systemd/system/ltvb-agent.service

# 5. Templates. `install` and not `cp`: the point is the -o/-g/-m, and a
#    template that ends up owned by the checkout's uid is the hole this whole
#    directory exists to close. The daemon carries its own copies, so this step
#    is only needed to override them — but the MANAGER's two renderers
#    (NginxConfig, SystemdUnit) read from here and have no built-in fallback in
#    production, so on this server it is not optional.
#
#    The nginx template is FLAT, in the daemon's own directory, because the
#    daemon and the manager now render the same file: the daemon resolves it as
#    the bare name `nginx-site`, and putting it anywhere else would give the
#    manager a second copy to disagree with. Install it in the same step as the
#    daemon — the two are one unit, and a template installed ahead of a daemon
#    that does not send its variables makes nginx.site.write fail.
install -o root -g root -m 0755 -d /etc/ltvb/agent/templates/systemd
install -o root -g root -m 0644 deploy/templates/nginx/*.erb        /etc/ltvb/agent/templates/
install -o root -g root -m 0644 deploy/templates/systemd/*.erb      /etc/ltvb/agent/templates/systemd/
#    Left over from when the manager had templates of its own; nothing reads
#    them now, and a stale template is a trap for whoever edits one next.
rm -rf /etc/ltvb/agent/templates/nginx

#    Nothing under /etc/ltvb may be writable by anyone but root. Check, do not
#    assume — this is the one invariant the manager cannot enforce for itself.
find /etc/ltvb -\! -user root -o -perm /022 | grep . && echo 'FIX THIS BEFORE STARTING'

# 6. The directories the verbs write into, and the group that reads site logs.
groupadd -f ltvb-log
install -o root -g root     -m 0755 -d /etc/ltvb/nginx/sites /etc/ltvb/nginx/snippets
install -o root -g ltvb-log -m 2750 -d /var/log/ltvb/sites

# 7. Verify BEFORE starting: config parses, users and group resolve, every verb
#    in the schema has a handler.
/usr/local/sbin/ltvb-agentd --check

systemctl daemon-reload && systemctl enable --now ltvb-agent
systemctl status ltvb-agent
```

Re-run step 5 whenever `deploy/templates/**` changes in the checkout, and run
`ruby deploy/agent/embed-nginx-template` first so the daemon's built-in copy of
`nginx-site.erb` matches the file being installed. It is a root action on
purpose: a deploy that could reinstall these could reinstall anything root
renders.

Log rotation is logrotate's job, not the agent's:

```
/var/log/ltvb-agent/audit.log {
  weekly
  rotate 52
  compress
  missingok
  notifempty
  create 0600 root root
}
```

### Moving the manager onto its own uid

`ltvb-apps-jobs.service` and the Passenger vhost both still run as `ltvb`. Until
they run as `ltvb-manager`, add `"ltvb"` to `allowed_users` — and understand
that while it is there, every app sharing that uid can call the agent. That
temporary widening is the whole reason `SO_PEERCRED` is in this design.

## Config files

| Path | Purpose |
|---|---|
| `/etc/ltvb/agent/agent.json` | `allowed_users`, `socket_group`, `service_globs` |
| `/etc/ltvb/agent/webspaces.json` | domain → owner + `manageable`; the only source of paths |
| `/etc/ltvb/agent/templates/*.erb` | the agent's own templates; each has a copy compiled into the daemon |
| `/etc/ltvb/agent/templates/nginx-site.erb` | the ONE nginx site template — the agent renders it to write the file, `NginxConfig` renders the same file to preview and test it |
| `/etc/ltvb/agent/templates/nginx-http-shared.erb` | the `http{}` half (log format, scrub maps, TLS session zone), rendered by `NginxConfig` |
| `/etc/ltvb/agent/templates/systemd/*.erb` | read by the manager's `SystemdUnit` |

All are optional — the agent has a compiled-in default matching this server —
but a file that exists and is untrusted (symlink, wrong owner, group-writable)
is fatal rather than ignored. Silently falling back to a default because an
attacker chmod'd a file is the wrong behaviour.

`systemctl reload ltvb-agent` (SIGHUP) re-reads all of them in place; a restart
would drop the socket and anything mid-deploy with it. A reload that fails to
parse leaves the previous config running and logs `reload_failed`.

## Protocol

NDJSON over `SOCK_STREAM`, one request object per line, one response object per
line, answered in order. Several requests may share a connection.

```
-> {"id":"a1b2","verb":"http.check","params":{"fqdn":"git.ltvb.nl","path":"/up"}}
<- {"id":"a1b2","ok":true,"out":"","err":"","data":{"code":200,...},"duration_ms":41}
```

`ping` is the handshake and returns `{agent_version, protocol, verbs:[…]}`. The
Rails client (`app/services/agent.rb`) refuses to proceed on a protocol
mismatch: the agent is installed by root and the client by a deploy, so the two
genuinely can drift, and a client that guesses at a contract it does not
understand is how a parameter comes to mean something else on the root side.

Error responses carry a machine-readable `code`:

| code | meaning |
|---|---|
| `unknown_verb` | not in this agent's schema |
| `schema` | a parameter failed validation |
| `unknown_domain` | the hostname belongs to no webspace |
| `not_manageable` | the webspace is read-only for the manager |
| `denied` | caller uid is not in `allowed_users` |
| `oversize` | request line over 1 MiB |
| `busy` | another mutating call holds the lock |
| `timeout` | the child outran its per-verb deadline |
| `validation` | staged file rejected; previous version is live |
| `broken` | rollback ran and the reload still fails — needs a human |
| `exec` | the underlying command failed |
| `io` | the filesystem refused (ENOSPC, EROFS, a planted symlink) |

## Verbs

`ping`, the seven inherited from `ltvb-deployer`, three discovery verbs, and the
fifteen that actually replace Plesk: enough to write a vhost, install a unit,
write an fpm pool and reload each of them without a Plesk licence.

| verb | mutating | notes |
|---|---|---|
| `ping` | no | handshake |
| `plesk.domains` | no | was `list-domains` |
| `plesk.subdomain.create` | yes | was `create-subdomain`; idempotent |
| `plesk.subdomain.docroot` | yes | was `set-docroot`; takes a `suffix`, not a www-root |
| `plesk.ruby.enable` | yes | was `enable-ruby`; enables *and* pins |
| `plesk.reconfigure` | yes | was `reconfigure` |
| `plesk.subdomain.remove` | yes | was `remove-subdomain` |
| `jobs.restart` | yes | was `restart-jobs`; `--no-block`, see below |
| `sites.discover` | no | the post-Plesk site inventory, read from disk |
| `services.discover` | no | systemd units + supervisor programs |
| `http.check` | no | loopback request with the host's own Host header and SNI |
| `nginx.site.write` | yes | render spec in, `/etc/ltvb/nginx/sites/<fqdn>.conf` out |
| `nginx.site.remove` | yes | same contract in reverse; restores on a failed reload |
| `nginx.test` | no | `ltvb-nginx -t`; a failure is a *result*, not an error |
| `nginx.reload` | yes | test then reload |
| `systemd.unit.install` | yes | `ltvb-app@<fqdn>.service`, or a worker beside it |
| `systemd.unit.remove` | yes | disable `--now`, unlink, daemon-reload |
| `systemd.daemon_reload` | yes | |
| `systemd.enable` / `.disable` | yes | optional `now` |
| `systemd.restart` | yes | `action` enum (start/stop/restart/reload/…), `block` |
| `systemd.status` | no | a fixed property list, never the whole `systemctl show` |
| `systemd.journal` | no | last N lines, N ≤ 5000 |
| `fpm.pool.write` | yes | `/etc/php/<v>/fpm/pool.d/<fqdn>.conf` |
| `fpm.reload` | yes | `php-fpm<v> -t` then reload |
| `dir.ensure` | yes | `logs`, `releases` or `shared` — see below |

### What the new verbs will and will not take

- **`nginx.site.write` takes a render spec, not config.** `kind` is one of
  `rails/php/laravel/static`; the rest is `suffix`, `staging`, `tls`, `hsts`,
  `redirect_http`, `default_server`, `php`, `allow` (literal IPs and CIDRs
  only — a hostname would make nginx resolve at load time and then permit
  whatever that name points at later), `cable_path`, `cable_port`. The document
  root, socket, cert dir, log dir and fpm socket are all derived from the fqdn.
- **Unit names are derived, never sent.** `systemd.unit.install` composes
  `ltvb-app@<fqdn>.service`, or `ltvb-<worker>-<fqdn-with-dashes>.service`, and
  runs it as the webspace's own owner from the webspace table. The app unit's
  `ExecStart` is derived too — sending `argv` for one is an error, and omitting
  it for a worker is also an error.
- **Two tiers of unit name.** `systemd.status` and `systemd.journal` accept any
  well-formed unit name plus a four-entry legacy allowlist (`php8.<n>-fpm`,
  whose dot the pattern refuses, and `postfix@-`). Everything that *acts* —
  install, remove, enable, disable, restart — additionally requires the name to
  match a controllable shape: `ltvb-*`, `ltvb-app@*`, `git-ltvb-*`,
  `php8.<n>-fpm`. `ssh.service` is readable and not stoppable, and
  `ltvb-agent.service` is explicitly never controllable — the call that stopped
  it would be the last one answered.
- **`dir.ensure` before `nginx.site.write`.** nginx refuses to *start* when a
  directory named in `access_log` is missing, so `dir.ensure kind=logs` is a
  prerequisite of the first site write, not a tidy-up after it. It creates
  `/var/log/ltvb/sites/<fqdn>` as `root:ltvb-log` 2750.
- **Reload means test-then-reload, and skips a server that is not up.** During
  the migration `ltvb-nginx.service` does not exist yet; `nginx -t` passing is
  the whole check at that point, and refusing every write until the server runs
  would mean the tree could never be built to start it with.
- **Env values reject newlines rather than escaping them.** systemd parses a
  unit line by line: a value of `"x\nExecStartPre=/bin/sh -c …"` does not
  corrupt a value, it adds a command root runs. `env` is marked `secret: true`,
  so the audit log gets its variable *names*, a sha256 of the canonicalised map
  and its byte count — never a value.

### Serving the customer webspaces

`nginx.site.write`, `fpm.pool.write`, `systemd.unit.install` and `dir.ensure` are
mutating, so they inherit the `manageable` policy: refused on djtim.eu,
rijschool-mos.nl, voordezorgmanagement.nl and mos-safeguards.com. Post-Plesk
those four still have to be served. Flipping `manageable` for them is a root edit
of `webspaces.json` and a `systemctl reload ltvb-agent` — deliberately a decision
someone makes, not a code change and not something the manager can ask for.

`jobs.restart` keeps `systemctl restart --no-block`. The caller is itself a job
inside `ltvb-apps-jobs`, so a blocking restart waits on the worker that is
waiting on the call — deadlocked until SIGKILL.

`http.check` dials `127.0.0.1` with `Net::HTTP#ipaddr=` so the Host header and
SNI are the real hostname. That tests *this server's* vhost selection rather
than the network, and it reaches the staging ports (9080/9443) that are
firewalled off from outside.

`sites.discover` lists directories matching `<label>.<domain>` under each
webspace, which is what keeps `logs/`, `bin/`, `error_docs/` and the assorted
`.bak` and `.laravel-leftovers` strays out of the inventory without a
hand-maintained exclusion list.

## Adding a verb

Growth is meant to be mechanical. Nothing outside these two steps knows the verb
list, so a new verb cannot forget validation, timeouts, locking or auditing.

1. Add an entry to `Schema::VERBS`:

   ```ruby
   "certbot.issue" => {
     summary: "issue or renew a certificate for a host", mutating: true, timeout: 300,
     params: {
       fqdn:    { type: :fqdn, required: true },
       staging: { type: :bool, default: false }
     }
   },
   ```

   Types available: `label`, `version`, `relpath`, `url_path`, `line`, `text`,
   `bool`, `port`, `size`, `count` (needs `min:`/`max:`), `enum` (needs
   `values:`), `argv`, `env`, `ip_list`, `unit`, `managed_unit`, `domain`,
   `fqdn`. Two tests keep the schema honest: every default is re-run through its
   own coercer, and every `enum`/`count` must declare the bounds `coerce!`
   fetches.

2. Add `def verb_nginx_site_write(params, timeout)` to `Handlers`. It receives
   values that are already validated, so it contains no validation of its own.

`mutating: true` gets the lock, the start-and-finish audit pair, and a check
that the `fqdn`/`domain` resolves to a *manageable* webspace. `--check` fails
if a schema entry has no handler.

Rules for handler bodies:

- Derive paths with `@webspaces.resolve(params[:fqdn])`. Never build one from a
  parameter.
- Render config with `Templates.render("name", vars)` — a literal name.
- Install it with `AtomicWrite.replace(path, text, validate:, reload:)`, where
  `reload` test-then-reloads (`nginx -t && systemctl reload nginx`). Some
  validators only work on a whole tree, and activating an untested tree is the
  thing that mechanism exists to prevent.
- Shell out only through `Exec.run`, with an absolute `argv[0]`.
- Mark any secret parameter `secret: true` so the audit log gets its digest and
  not its value.

## Testing

`test/services/agent_protocol_test.rb` attacks the schema, the type predicates,
the webspace table, the unit-name tiers, the template resolver, the renderers
and the file-replacement logic directly — no socket, no root. That is
deliberate: the security-critical code is written as pure functions specifically
so it can be tested by `bin/rails test`, because a test that needs a live root
daemon is a test that stops being run.

Four of those tests are invariants rather than cases, and are the ones to read
first if a change to this file starts failing:

- no verb declares a parameter named for a path, a file or a body of config;
- every schema default is re-run through the coercer that would have validated it;
- every unit shape that is *readable* is checked against the smaller set that is
  *controllable*, including that `ltvb-agent.service` is in neither;
- the free-text types (`argv` elements, `env` values, a `Description=`) accept
  punctuation and reject only what ends a line.

```sh
bin/rails test test/services/agent_protocol_test.rb
ruby deploy/agent/ltvb-agentd --verbs     # the schema, as JSON
ruby deploy/agent/ltvb-agentd --check     # config + handler coverage (needs the server)
```

## Decommissioning ltvb-deployer

`app/services/plesk.rb` still calls `PrivilegedShell`. Move it verb by verb
(`Plesk.create_subdomain` → `Agent.call("plesk.subdomain.create", …)`) — the
`Result` shape is identical, so call sites do not change. Once nothing calls it:

```sh
rm /etc/sudoers.d/ltvb-deployer /usr/local/sbin/ltvb-deployer
```
