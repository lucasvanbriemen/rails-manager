# Webmail

`apt remove` on the Plesk packages deletes the webmail application itself.
Roundcube here is not a thing we installed next to Plesk — it *is* a Plesk deb,
and all 3125 files under `/usr/share/psa-roundcube` are dpkg-owned. There is no
"keep the app, drop the panel" path.

Measured on the live box on 2026-08-15. Raw captures under
`/root/plesk-export/webmail/` — `database.txt`, `packages.txt`, `tls.txt`,
`vhosts/`, `config/` (secrets recorded as key names only).

## What exists today

```
plesk-roundcube  1.6.18-v.ubuntu.24.04+p18.0.80.2+t260810.1556   22.9 MB, 3125 files
```

Served from `/usr/share/psa-roundcube` by two Apache vhosts —
`webmail.ltvb.nl` and `webmail.lucasvanbriemen.nl`. The other 18 files in
`/etc/apache2/plesk.conf.d/webmails/` are 189-byte
`# Webmail is not enabled on the domain` stubs.

PHP runs through `/var/www/cgi-bin/cgi_wrapper/cgi_wrapper` (from the
`plesk-web-hosting` deb) under mod_fcgid, with
`FcgidInitialEnv PP_CUSTOM_PHP_CGI_INDEX "plesk-php83-fastcgi"` — that is
Plesk's own PHP 8.3.33 from `/opt/plesk/php/8.3`, 27 `plesk-php83-*` packages,
not the distro's `php8.3-cli`.

One correction to the finding as written: the wrapper is **not setuid**. It is
`-rwxr-xr-x root:root`; privilege separation comes from
`SuexecUserGroup roundcube_sysuser roundcube_sysgroup` (uid 986, gid 1009) via
mod_suexec. That matters for a replacement, because nginx has no suexec — the
equivalent is a dedicated php-fpm pool running as that user, which is the same
shape as the per-domain pools in `_php_fpm.conf.erb`.

Config is a five-line `config.inc.php` that sets exactly one key,
`$config['db_dsnw']` (mysql, `localhost`, database `roundcubemail`). Everything
else comes from the stock `defaults.inc.php` (259 keys). There is no
`config.local.php`. The DB password lives in the DSN and in
`config/.roundcube.shadow` (15 bytes, `root:root 0640`); neither value is in the
export.

## Who actually uses it

This is the number that should drive the decision.

```
user_id  username                        created              last_login
6        contact@lucasvanbriemen.nl      2026-02-23 00:04:18  2026-08-12 02:26:48   <- 3 days ago
5        info@mos-safeguards.com         2026-02-17 19:37:58  2026-02-17 19:37:58   <- 6 months
3        ntfy@ltvb.nl                    2026-01-03 14:54:09  2026-01-16 19:08:16   <- 7 months
2        development@lucasvanbriemen.nl  2025-06-14 11:04:23  2025-06-14 11:04:23   <- 14 months
```

Four accounts. Three logged in exactly once, on the day they were created.
**One person has used webmail in the last six months.**

The database is 1.53 MB across 17 tables, and almost all of it is session rows:

```
contacts  identities  canned_responses  saved_searches  collected_addresses  dictionary
0         4           0                 0               3                    0
```

Zero contacts. Four identities (the auto-created default per user) and three
collected addresses. **There is no user data to migrate.** Roundcube is a view
onto IMAP; the mail itself is in `/var/qmail/mailnames/` and is untouched by any
of this.

`horde` is also still on the box — 5.91 MB, 106 tables, `horde_users` = 0. It is
Plesk's other webmail, never used. Drop it.

## TLS, which is the real cost

Neither webmail host has a certbot lineage, and the gap is wider than it looks.
All 21 lineages in `/etc/letsencrypt/renewal/` are **single-SAN** — the
`ltvb.nl` lineage covers `DNS:ltvb.nl` and nothing else.

The certificate actually served on `webmail.ltvb.nl` today is a four-SAN cert
(`ltvb.nl, mail.ltvb.nl, webmail.ltvb.nl, www.ltvb.nl`) issued by Plesk's own
Let's Encrypt extension and stored at
`/opt/psa/var/certificates/scf4lrem519afuheGJZodY`. That directory is Plesk's
and goes away with it.

Names served today with **no certbot lineage to fall back on**:

```
webmail.ltvb.nl              expires 2026-10-30
webmail.lucasvanbriemen.nl   expires 2026-09-23
mail.lucasvanbriemen.nl      (dovecot SNI references it)
www.ltvb.nl
www.lucasvanbriemen.nl
```

`mail.ltvb.nl` does have its own lineage; `mail.lucasvanbriemen.nl` does not.
So this is not only a webmail problem — dovecot's SNI blocks read from the same
doomed `/opt/psa/var/certificates/` path. See the same section in
`deploy/AUTODISCOVER.md`.

Keeping webmail therefore means issuing and renewing two more certificates that
nothing else needs.

## Options

### Option 1 — drop webmail

Let `apt remove` take it. Delete the `roundcubemail` and `horde` databases and
the `roundcube_sysuser` account. Do not create the two vhosts or the two
certificates.

Cost: one person (`contact@lucasvanbriemen.nl`) loses a browser mailbox and has
to use a mail client. Zero data lost — no contacts, no filters, no saved
searches exist. Nothing else on the box depends on it.

### Option 2 — reinstall upstream Roundcube ourselves

Upstream 1.6.x from the tarball into `/opt/ltvb/roundcube`, a dedicated php-fpm
pool as a `roundcube` user (replacing suexec), an nginx vhost per webmail host,
a fresh `config.inc.php` with a new DB user, two new certbot lineages, and the
existing `roundcubemail` schema carried over (or recreated — there is nothing in
it worth keeping).

Cost: a new internet-facing PHP application to keep patched, on our own
schedule, for one active user. Roundcube ships security releases regularly and
this box has no mechanism for that today — the distro's `php8.3-fpm` would
handle the interpreter, but the app is ours. Plus the two certificates above.

Note the distro's php8.3-cli is already installed and is what the surviving
Laravel crons use, so this does not require keeping any `plesk-php83-*` package.

### Option 3 — hosted webmail, no local install

Point `contact@lucasvanbriemen.nl` at any IMAP-capable client and drop the
`webmail.*` names entirely, or CNAME them to a hosted client.

Cost: whatever the third party costs; no local attack surface, no certificates,
no patching.

## Recommendation

**Option 1.** Four accounts, one of them active, zero rows of user data, and the
carrying cost is a permanently internet-facing PHP application plus two
certificates that exist for nothing else. Reinstalling Roundcube would be
re-adopting the single largest piece of unpatched attack surface Plesk was
providing, to serve one person who could use a mail client instead.

Before removal, tell `contact@lucasvanbriemen.nl` the settings from
`deploy/AUTODISCOVER.md` — IMAP `lucasvanbriemen.nl:993` SSL, SMTP
`lucasvanbriemen.nl:465` SSL, username = full address — since that domain is one
of the two whose mail hostname does present a valid certificate.

If webmail is wanted later, Option 2 is a clean greenfield install; there is no
migration to preserve and nothing about this decision is one-way.

## Order of operations

The webmail vhosts and dovecot both read certificates from
`/opt/psa/var/certificates/`. Whichever option is chosen, **dovecot and postfix
must be repointed at `/etc/letsencrypt/live/` before the Plesk packages are
removed**, and the missing lineages (`mail.lucasvanbriemen.nl` at minimum, plus
the two `webmail.*` names if webmail survives) must be issued while Apache is
still serving `/.well-known/acme-challenge` from
`/var/www/vhosts/default/htdocs`. Getting that order wrong takes IMAP and SMTP
down, not just webmail.
