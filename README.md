# ltvb-apps — a deploy manager for Rails apps on the Plesk server

A small Rails app (served at **apps.ltvb.nl**) that creates, deploys, and manages
the other Rails apps on this Plesk + Apache/Passenger server — encoding the deploy
recipe so a misconfigured document root, missing `master.key`, empty `.env`, or
un-installed gems can't silently break a site again. It also flags apps that are
serving the Plesk placeholder instead of Rails.

## Why

Deploys here kept breaking the same way (most recently `git.ltvb.nl`): Plesk
points a subdomain's document root at the app folder instead of `public/`, so
Passenger never finds the app and Apache serves the Plesk default page. Combined
with a missing `config/master.key`, an empty `.env`, and no gems, the site is
dead. This tool turns that ~12-step fix into one button.

## The deploy recipe (what `DeployRunner` automates)

1. **Provision** (new app): `create-subdomain` → `set-docroot` to `<app>/public`
   (the gotcha — Plesk defaults to the app root) → `enable-ruby` (turn on
   Passenger + pin the version, else Apache 403s) → `reconfigure` the vhost.
2. **Fetch code**: `git clone`/`git reset --hard` *or* unpack an uploaded tarball.
3. **Secrets**: write `config/master.key` + `.env` (stored encrypted in this app).
4. **Gems**: `bundle install` using the app's **rbenv** Ruby (the system Ruby
   lacks headers, so native gems fail — a real trap hit during the manual fix).
5. **Databases**: create/migrate the **secondary** SQLite DBs (cache/queue/cable).
   An **external/shared primary** DB is never auto-migrated — that's a separate,
   confirmed button.
6. **Assets**: `SECRET_KEY_BASE_DUMMY=1 rails assets:precompile`.
7. **Restart**: `touch tmp/restart.txt`.
8. **Verify**: HTTP-check the live site is Rails (not the Plesk placeholder/5xx).

## Architecture

- Runs as the unprivileged `ltvb` user via Passenger. All non-root steps (git,
  bundle, rails tasks, file writes, restart) run directly as `ltvb`.
- Root-only Plesk operations go through **one** vetted wrapper,
  `/usr/local/sbin/ltvb-deployer` (see `deploy/ltvb-deployer`), callable by `ltvb`
  via a scoped `sudoers` rule. The wrapper validates every argument (hostname
  shape, domain allowlist, no `..`) — it is the trust boundary.
- Deploys run as **Solid Queue** jobs (`deploy/ltvb-apps-jobs.service`); the live
  log view polls a JSON endpoint (no websocket dependency under Passenger).
- Access is gated by the ltvb SSO (`login.ltvb.nl`) **and** an admin allowlist
  (`ADMIN_EMAILS` in `.env`) — fails closed.

## One-time server bootstrap (as root)

```sh
# 1. Install the privilege bridge
install -o root -g root -m 0755 deploy/ltvb-deployer        /usr/local/sbin/ltvb-deployer
install -o root -g root -m 0440 deploy/ltvb-deployer.sudoers /etc/sudoers.d/ltvb-deployer
visudo -cf /etc/sudoers.d/ltvb-deployer

# 2. Deploy this app once, by hand, with the same recipe it automates:
#    create subdomain apps.ltvb.nl, set docroot to apps.ltvb.nl/public, reconfigure,
#    push code, write .env (+ AR encryption keys + ADMIN_EMAILS) and config/master.key,
#    bundle install (rbenv), db:prepare, assets:precompile, touch tmp/restart.txt.

# 3. Install + start the job worker
install -o root -g root -m 0644 deploy/ltvb-apps-jobs.service /etc/systemd/system/ltvb-apps-jobs.service
systemctl daemon-reload && systemctl enable --now ltvb-apps-jobs
```

## Configuration (`.env`, see `.env.example`)

- `ADMIN_EMAILS` — comma-separated SSO emails allowed to use the manager.
- `AR_ENCRYPTION_*` — keys for encrypting stored `master.key`/`.env` values.

## Known gotchas (surfaced while building this)

- **Plesk default page.** A new subdomain's docroot defaults to the app folder,
  not `public/`; Plesk also drops a "Domain Default page" `index.html` into the
  docroot. With Passenger on, that static index shadows Rails. The recipe fixes
  the docroot and removes the placeholder.
- **Ruby/Passenger must be enabled** per subdomain (`plesk ext ruby --enable`),
  else Apache 403s. Done by the `enable-ruby` step.
- **`bundle install` must use the rbenv Ruby**, not the system Ruby (missing
  headers → native gem build fails).
- **Passenger + bundler default-gem conflict.** Passenger's pure-Ruby loader
  (native support disabled here) pre-activates Ruby's *default* `stringio`
  before `bundler/setup`. If an app's lock resolves a newer `stringio`, the spawn
  dies with `You have already activated stringio X, but your Gemfile requires Y`.
  Fix: pin it to the Ruby default in the app's Gemfile, e.g. `gem "stringio", "3.1.1"`,
  and re-bundle. The manager's verify step catches this (site won't boot) and the
  deploy is marked failed rather than silently "deployed".

## Local development

```sh
bundle install && bin/rails db:prepare
bin/dev        # Procfile.dev: web + dartsass watch
```
Local auth/Plesk calls won't work off-server, but the app boots and the UI renders.
