# Backups

Every number below was measured on `server.ltvb.nl` on 2026-08-15 by running
`BackupRunner` against the live 16 databases, 20 SQLite files, 6 app checkouts
and 11 config trees, then restoring its dumps into scratch databases and
comparing them. Nothing here is an estimate unless it says so.

The run this document describes:

```
/var/backups/ltvb/20260815T202345Z
partial   53 files   139,611,599 bytes (133.1 MiB)   34.4 s wall clock
verify    passed
code      backup_runner.rb  f534919637f920f39b87180b6c5040e356e45c04ade2ba73b7a70321d4463b88
          backup.rb         6add88ef80af7eb89d305772f68824aa60053ca4669b1e387ac081bfdcca85d9
```

`partial` is correct and is the most useful thing the run said. See "what it
does not cover".

## Why this exists, and what it is actually replacing

The class comments call Plesk's `/opt/psa/bin/mysqldump.sh` "the only automatic
backup this server has". That is true, and it is worse than it sounds. Its
output, `/var/lib/psa/dumps/mysql.daily.dump.0.gz`, is 1.57 MB and contains
exactly five databases:

```
psa  mysql  horde  roundcubemail  phpmyadmin
```

All five are Plesk's own. **Eleven application databases have never had an
automatic backup at all** — `gitub_gui`, `email.lucasvanbriemen.nl`, `music`,
`mos_safeguards`, `rijles`, `compoments`, `senne_bday`,
`voordezorgmanement.nl`, `opendmarc`, `email_test`, `music_test` — and neither
have the 20 SQLite databases, the app secrets, the Maildirs or any config. This
is not a like-for-like replacement of something that worked. It is the first
backup most of this data has ever had.

## How to run it

```sh
rake backup:plan                # print what a run would take, touch nothing
rake backup:run                 # take a backup, then prove one dump restores
rake backup:run SKIP_VERIFY=1   # ... recorded as verify_status=skipped, not as verified
rake backup:verify              # re-prove the newest backup on disk
rake backup:verify DATABASE=gitub_gui   # ... a named database instead of the sample
rake backup:prune DRY_RUN=1     # show what retention would delete
rake backup:status              # last run, last VERIFIED run, exclusions
```

All of it needs root. The webspaces are `0750 owner:psaserv`,
`/etc/letsencrypt/{live,archive}` are `0700`, `/etc/ltvb` and the crontabs are
root-only, and the MariaDB credentials are in a root-owned `my.cnf`.
`rake backup:run` warns and continues as a non-root user, and the run comes back
`partial` with the list of what it could not read — it does not pretend.

Credentials come from `/etc/ltvb/backup.cnf` if it exists, otherwise from
`/etc/mysql/debian.cnf`. **`/etc/ltvb/backup.cnf` does not exist on the server
today**, so this run used Debian's maintenance account — which works, and is
root-only, which is the property that matters. Install the project's own file
before this is scheduled. Neither ever appears in `argv`: `/proc/<pid>/cmdline`
is world-readable and six webspace uids share this box.

### Scheduling it

`deploy/ltvb-backup.service` and `deploy/ltvb-backup.timer` are in this repo and
are **not installed on the server**. There is no cron entry and no systemd timer
for `backup:run` today; the only backup timer systemd knows about is
`dpkg-db-backup`. Meanwhile `/etc/cron.daily/50plesk-daily` still runs every
morning and dies with the licence on 2026-09-01.

```sh
install -o root -g root -m 0644 deploy/ltvb-backup.service /etc/systemd/system/
install -o root -g root -m 0644 deploy/ltvb-backup.timer   /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now ltvb-backup.timer
systemctl list-timers ltvb-backup.timer
```

The unit's `ExecStart` uses `/var/www/vhosts/ltvb.nl/.rbenv/shims`, which is
still Plesk's Ruby. It needs to follow whatever the symlink swap to
`/opt/rbenv/versions/3.3.8` lands on.

## What one run captured

| kind | files | bytes | share | time |
|---|---:|---:|---:|---:|
| mysql | 16 | 70,951,393 | 50.8% | 23.8 s |
| sqlite | 20 | 23,469,163 | 16.8% | 6.0 s |
| files | 6 | 637,899 | 0.5% | 0.2 s |
| system | 11 | 44,553,144 | 31.9% | 4.1 s |
| **total** | **53** | **139,611,599** | | **34.4 s** |

### MariaDB — 16 databases, 23.8 s

Every schema on the server except `information_schema`, `performance_schema` and
`sys`, which are views over server state and cannot be restored. Row counts are
`COUNT(*)` captured at dump time, not `information_schema.table_rows`, which is
an InnoDB estimate — for `gitub_gui.workflow_jobs` the estimate says 164,883 and
the truth is 146,884.

| database | bytes (.sql.gz) | mode | tables | rows |
|---|---:|---|---:|---:|
| email.lucasvanbriemen.nl | 38,518,699 | full | 22 | 29,445 |
| gitub_gui | 30,366,051 | exclude_tables | 38 | 302,577 |
| psa | 1,111,052 | full | 169 | 8,944 |
| mysql | 531,403 | full | 30 | 5,837 |
| music | 241,193 | full | 19 | 10,637 |
| rijles | 58,806 | full | 6 | 2,877 |
| mos_safeguards | 54,545 | full | 24 | 949 |
| roundcubemail | 17,510 | full | 17 | 215 |
| compoments | 12,890 | full | 10 | 110 |
| senne_bday | 10,152 | full | 9 | 84 |
| horde | 8,898 | full | 106 | 29 |
| voordezorgmanement.nl | 8,877 | full | 10 | 71 |
| phpmyadmin | 3,829 | full | 19 | 43 |
| email_test | 3,205 | full | 22 | 9 |
| music_test | 2,804 | full | 19 | 11 |
| opendmarc | 1,479 | full | 9 | 0 |

`psa`, `roundcubemail` and `mysql` are kept on purpose and named in
`DELIBERATELY_KEPT`. The `mysql` dump's value was checked rather than assumed:
restored into a scratch database, `global_priv` comes back with all 10 rows and
an MD5 over `(User, Host, Priv)` identical to live. The grants survive.

`mysql` is also the only schema on this box with non-InnoDB tables (24 Aria,
2 CSV), so `--single-transaction` gives no snapshot guarantee for those. Every
other database is 100% InnoDB, so the flag does what the comment says everywhere
it matters.

### SQLite — 20 files, 6.0 s

Copied with `sqlite3 <src> ".backup '<dest>'"`, never `cp`. Every one of the 20
gunzips, passes `PRAGMA integrity_check` → `ok`, and has a clean
`PRAGMA foreign_key_check`.

```
aio.ltvb.nl    production_cable / _cache / _queue
apps.ltvb.nl   production / _cable / _cache / _queue
git.ltvb.nl    production_cable (104 MB) / _cache / _queue
login.ltvb.nl  production / _cable / _cache / _queue
mail.ltvb.nl   production_cable / _cache / _queue
music.ltvb.nl  production_cable / _cache / _queue
```

The manager's own `production.sqlite3` copy holds 7 `apps` rows and 92
`deployments` rows — the same counts as the live file read through its WAL.

One side effect worth knowing: `sqlite3 .backup` opens the source read-write, so
a run checkpoints the live WAL and (for an idle database) removes the `-wal` and
`-shm` beside it. That is a normal SQLite operation and loses nothing, but it
means the nightly job writes into app data directories as root. Checked after
both runs: no root-owned `-wal`/`-shm` was left anywhere under
`/var/www/vhosts/*/storage`.

### App files — 6 apps, 0.2 s

`.env`, `config/master.key` and `storage/`, tarred from inside the app so the
paths are relative, with `vendor`, `node_modules`, `.git`, `tmp`, `*.log` and
every `*.sqlite3*` excluded — the SQLite files are the previous phase's job, and
tarring them would be exactly the `cp` of a live WAL database this class exists
to avoid.

```
git.ltvb.nl  471,492    music.ltvb.nl  164,758    aio.ltvb.nl  596
mail.ltvb.nl    448     apps.ltvb.nl      427     login.ltvb.nl  178
```

Verified by extracting: `apps.ltvb.nl`'s restored `.env` and `config/master.key`
are byte-identical (`cmp`) to the live files.

### System config — 11 paths, 4.1 s

`/etc/ltvb`, `/etc/nginx`, `/etc/php`, `/etc/postfix`, `/etc/dovecot`,
`/etc/psa`, `/etc/letsencrypt`, `/etc/domainkeys`, `/etc/systemd/system`,
`/var/spool/cron/crontabs`, `/var/qmail/mailnames`. All eleven were readable, so
none of them is why the run is `partial`.

Three of these carry things nothing else on the box protects, so all three were
extracted into a scratch directory and diffed against the source:

* **`/etc/letsencrypt`** (38,718 bytes gz) — 21 certificate lineages with their private keys, 21 renewal
  configs and the ACME account key. `diff -r`: **identical**.
  Every one of the 20 site files in `/etc/ltvb/nginx/sites/` names
  `/etc/letsencrypt/live/<host>/fullchain.pem`, so without this the nginx config
  restores and nginx does not start. All 21 certs expire 2026-11-13 within two
  minutes of each other, which is also why re-issuing instead of restoring is a
  rate-limit problem.
* **`/etc/domainkeys`** (5,478 bytes gz) — the DKIM signing keys. `diff -r`:
  **identical**. Not reconstructible: regenerating them means every DNS TXT
  record has to change too.
* **`/var/qmail/mailnames`** (43,799,417 bytes gz, 84% of the config total) —
  the actual mail. **All 6,109 messages present**, ownership `popuser/popuser`
  preserved, and all 31 `dovecot-uidlist` files, 4 `subscriptions` files and 9
  `maildirsize` files preserved, so IMAP UIDs survive a restore.

  `diff -r` against the live tree shows ~90 "Only in" lines, all benign: the
  empty Maildir `tmp/` directories (transient by definition) and Dovecot's
  `dovecot.index.log` / `dovecot.list.index.log` / `dovecot.mailbox.log`, which
  Dovecot rebuilds. They are dropped by `TAR_EXCLUDES`' `tmp` and `*.log`
  patterns, which were written for Rails checkouts and happen to be right here
  too. Expect clients to re-sync headers after a mail restore; expect no lost
  messages.

`/etc/ltvb`'s archive also round-trips clean (`diff -r`, no differences), and
the crontabs archive holds all 6 including `root`, `psaadm` and `ltvb`.

## What it deliberately omits, and why

Three exclusions, each a named policy with a written reason, each recorded on the
`Backup` row's `excluded` column, in `manifest.json`'s `exclusions` array, and in
the run log. That is the design: a backup that quietly drops data is worse than
one that fails, because the failure gets noticed.

### `gitub_gui.incoming_webhooks`

Confirmed on the server: 18,251 MB of `gitub_gui`'s 18,647 MB — 97.9% of the
database — in 1,019,353 rows of raw GitHub webhook payloads (896k when the policy
was written; it grows continuously). They were already processed into
`workflow_jobs`, `commits` and `pull_request_comments`, all of which are dumped
in full.

The two-pass dump does what it claims. Restored into a scratch database:

```
tables in restore                       38   (live: 38)
incoming_webhooks present                1
incoming_webhooks rows                   0   (live: 1,019,353)
SHOW CREATE TABLE vs live                identical
foreign keys resolving                  27
CHECKSUM TABLE commits                   1325624234  (live: 1325624234)
CHECKSUM TABLE workflow_jobs             3853853353  (live: 3853853353)
CHECKSUM TABLE pull_request_comments      731253718  (live:  731253718)
```

`--ignore-table` alone would have dropped the `CREATE TABLE` too and produced a
restore where 27 foreign keys and every query naming the table break. Pass one
dumps structure for everything (`--no-data`), pass two dumps data for everything
else (`--no-create-info`). Concatenated gzip members are one valid gzip stream.

### `music.ltvb.nl:storage/audio` and `:storage/kokoro`

This one was measured the expensive way. An earlier run of the same class,
before these paths were excluded, is the reason the numbers below exist:

```
                        with storage/audio      without
wall clock                     302.7 s           34.4 s     (8.8x)
total bytes            7,054,660,801       139,611,599       (50x)
music.ltvb.nl tar      6,959,065,116           164,758
```

`storage/audio` is 6.3 GB of MP3 and `storage/kokoro` a 315 MB re-downloadable
model cache. Together they were 98.6% of the bytes and 90% of the time — 234.6 s
to `tar | gzip -9` and another ~37 s to sha256 the result. `gzip -9` turned
7,012,841,200 bytes into 6,959,065,116: **it saved 0.8%**, because the input is
already compressed.

`storage/kokoro` re-downloads. **`storage/audio` does not.** It is excluded, not
protected — it needs a copy off this box by some other route, and until it has
one, that is 6.3 GB with a single copy on a single disk.

## What it does not cover — why this run is `partial`

The run ended `partial`, with 14 problems, all the same problem:

```
/var/www/vhosts/ltvb.nl/ai.ltvb.nl                      looks like an app (it has a .env)
/var/www/vhosts/ltvb.nl/sandbox.ltvb.nl                 but has no App row — nothing in
/var/www/vhosts/ltvb.nl/senne.ltvb.nl                   this backup covers it
/var/www/vhosts/lucasvanbriemen.nl/agent.lucasvanbriemen.nl
/var/www/vhosts/lucasvanbriemen.nl/all.lucasvanbriemen.nl
/var/www/vhosts/lucasvanbriemen.nl/calendar.lucasvanbriemen.nl
/var/www/vhosts/lucasvanbriemen.nl/components.lucasvanbriemen.nl
/var/www/vhosts/lucasvanbriemen.nl/database.lucasvanbriemen.nl
/var/www/vhosts/lucasvanbriemen.nl/email.lucasvanbriemen.nl
/var/www/vhosts/lucasvanbriemen.nl/github.lucasvanbriemen.nl
/var/www/vhosts/lucasvanbriemen.nl/login.lucasvanbriemen.nl
/var/www/vhosts/lucasvanbriemen.nl/todo.lucasvanbriemen.nl
/var/www/vhosts/mos-safeguards.com/httpdocs
/var/www/vhosts/voordezorgmanagement.nl/httpdocs
```

The manager's `apps` table has 7 rows. There are 20 checkouts with a `.env` on
this disk and 6 of them have a row. `sqlite_sources` and `app_file_sets` enumerate `App` rows, so those 14
contribute nothing — no `.env`, no `master.key`, no uploads. Concretely,
`sandbox.ltvb.nl` has a `production.sqlite3` with `accounts` and `tokens` tables
that is one of the 24 SQLite databases on the box and one of the 4 this backup
does not hold.

This is the right behaviour — backups follow the model, and the alternative is a
backup that silently invents scope — but **the run stays `partial` until those
apps are registered**, and it should. `partial` here means "this is not a
complete backup of this server", which is exactly true.

Still outside the model entirely: `/root` (5.8 GB, including `plesk-export`,
`ltvb-phase0-backup` and `mail.private`).

## Restore

### One MariaDB database

```sh
S=ltvb_verify_$(openssl rand -hex 8)
mysql --defaults-file=/etc/mysql/debian.cnf -e "CREATE DATABASE \`$S\`"
gzip -dc /var/backups/ltvb/<stamp>/mysql/<database>.sql.gz \
  | mysql --defaults-file=/etc/mysql/debian.cnf "$S"
# compare, then:
mysql --defaults-file=/etc/mysql/debian.cnf -e "DROP DATABASE \`$S\`"
```

Restore into a scratch name first, always. `rake backup:verify` does exactly
this and drops the scratch in an `ensure`; the `ltvb_verify_` prefix is checked
when the name is minted and re-checked immediately before the `DROP`.

To restore over the real database, name it instead of `$S` — the dumps contain
no `CREATE DATABASE` and no `USE`, so the target is whatever is on the command
line and nothing else.

Measured against this run's dumps:

| database | .sql.gz | restore + compare | result |
|---|---:|---:|---|
| email.lucasvanbriemen.nl | 38.5 MB | 58.2 s | 22 tables, 29,445 rows matched |
| gitub_gui | 30.4 MB | 11.4 s | 38 tables, 302,577 rows matched |
| psa | 1.1 MB | 1.6 s | 169 tables, 8,944 rows matched |
| music | 241 KB | 0.4 s | 19 tables, 10,637 rows matched |
| roundcubemail | 17.5 KB | 0.2 s | 17 tables, 215 rows matched |
| mysql | 531 KB | 0.4 s | **failed** — see below |

Restores are `INSERT`-bound, not size-bound: `email.lucasvanbriemen.nl` takes 5×
longer to restore than `gitub_gui` from a similar-sized dump. A full restore of
all 16 databases is therefore on the order of 90 seconds, against 24 seconds to
dump them.

### One SQLite database

```sh
gzip -dc /var/backups/ltvb/<stamp>/sqlite/<slug>.gz > production.sqlite3
sqlite3 production.sqlite3 'PRAGMA integrity_check;'   # expect: ok
```

The slug is the full path with `/` turned into `-`, e.g.
`ltvb.nl-git.ltvb.nl-storage-production_queue.sqlite3.gz`. Five apps have a file
called `production_queue.sqlite3`, so a basename-only scheme would lose four of
them. There is no `-wal` beside the copy and there should not be: `.backup`
produces a single checkpointed file.

### App files, config, and mail

```sh
tar -xzf /var/backups/ltvb/<stamp>/files/<slug>.tar.gz    -C /var/www/vhosts/<domain>/<dir>
tar -xzf /var/backups/ltvb/<stamp>/system/etc-ltvb.tar.gz -C /etc
tar -xzf /var/backups/ltvb/<stamp>/system/etc-letsencrypt.tar.gz -C /etc
tar -xzf /var/backups/ltvb/<stamp>/system/var-qmail-mailnames.tar.gz -C /var/qmail
```

Paths inside the archives are relative (`.env`, `ltvb/nginx/…`,
`mailnames/<domain>/<user>/…`), so `-C` chooses the destination. Extract as root
so ownership is preserved — `popuser:popuser` for the Maildirs, `ltvb:psacln` in
the webspaces — and restart Dovecot after a mail restore so it rebuilds the
index files the archive deliberately does not carry.

### Checking a backup before you trust it

`manifest.json` carries size and sha256 for all 53 files, and the same list is
on the `Backup` row so it survives the directory being pruned or the disk being
lost. Re-checked after the run: **53 items, 0 mismatches.**

## Verification

`rake backup:run` restores one dump into a scratch database and compares it
table-for-table and row-for-row against the counts captured at dump time — not
against the live database, whose rows move under you. On this run it passed, on
`music_test`: 19 tables, 11 rows.

The sample is the smallest full dump **that recorded a positive row count**,
which matters more than it looks. The smallest full dump on this server is
`opendmarc`, which has 9 tables and 0 rows; a comparison of zero against zero
exercises no data path at all and would still report `passed`. With the row
filter the sample is `music_test` instead — real, but 11 rows. For a
verification that proves something, name one:

```sh
rake backup:verify DATABASE=gitub_gui    # 302,577 rows across 38 tables, 11.4 s
```

### `mysql` does not round-trip, and `mysqldump` says nothing

This is the one open defect found by running the thing.

```
row count mismatch: innodb_index_stats expected 4089, restored 0
                    innodb_table_stats expected 490, restored 0
```

`mysqldump` writes the `CREATE TABLE` for both and no `INSERT`s. It exits 0 and
prints nothing on stderr — verified by running the identical argv by hand and
capturing stderr, which was empty. Reproduced identically on both runs.

These are InnoDB's persistent optimizer statistics. The server regenerates them
and losing them costs nothing but the first few query plans. Three things follow
that do matter:

1. The manifest records 4,089 and 490 expected rows for tables the dump can
   never produce, so the manifest is wrong about its own contents.
2. Any run whose verification sample were `mysql` would fail forever, for a
   reason that is not a fault. Today the sample is chosen by size, so this is
   latent rather than active.
3. It is a silent omission by a tool this class trusts — precisely the failure
   mode `POLICIES` exists to make impossible. It is not covered, because the
   policy machinery describes what `BackupRunner` chooses to leave out, not what
   `mysqldump` leaves out on its own.

The fix is a policy naming those two tables so the omission is declared rather
than discovered. Until then: `mysql` verification failure is expected, and the
grants — which is what that dump is for — do restore.

One smaller note on the same path: restoring a `--routines` dump into a scratch
database creates those routines **in that scratch database**, which adds rows to
the live `mysql.proc` for the lifetime of the scratch (observed: 50 → 52 → 50).
They go away with the `DROP DATABASE`, and the drop is in an `ensure`.

After eleven scratch restores across both runs, `SHOW DATABASES` returns the
original 19 and `SHOW DATABASES LIKE 'ltvb_verify%'` is empty.

## Does the retention schedule fit?

`RETENTION` is 7 daily + 4 weekly + 6 monthly, counted in distinct buckets that
exist rather than in days elapsed, plus the newest run and the newest *verified*
run. At most 18 directories.

| | per run | × 18 | share of free |
|---|---:|---:|---:|
| **as measured** | **133.1 MiB** | **2.3 GiB** | **0.9%** |
| with `storage/audio` included (measured) | 6.57 GiB | 118.3 GiB | 44% |
| as `Backup::RETENTION`'s comment estimates | ~1 GB | ~17 GB | 6% |

Free on `/`, which holds `/var/backups`: 286,701,223,936 bytes = **267.0 GiB**.
So: **yes, comfortably** — the whole schedule costs less than 1% of free space,
and the box could hold about 2,000 runs.

Two things about that table are worth keeping in view. The `~1 GB per run`
estimate written into the retention comment was never right in either direction:
it is 7.5× the real cost now and was 6.6× *under* the real cost while
`storage/audio` was included. And the arithmetic that justifies excluding
`incoming_webhooks` — "~320 GB against 274 GB free" — is derived from that same
estimate, so it should be restated against measured numbers: including the table
would add roughly 18 GB per run, or ~320 GB across the schedule, against 267 GiB
free. The conclusion holds; the figure it rests on should be a measurement.

The pressure now is elsewhere: at 133 MiB a run, the schedule is free, and the
thing to watch is `email.lucasvanbriemen.nl` and `gitub_gui`, which together are
50% of every run and both grow.

## Reproducing this

The deployed checkout at `/var/www/vhosts/ltvb.nl/apps.ltvb.nl` predates the
backup code and its SQLite database has no `backups` table, so these runs loaded
`app/services/backup_runner.rb` and `app/models/backup.rb` verbatim from the repo
(sha256 confirmed byte-identical on both ends), booted ActiveRecord 8.0.5 against
a throwaway SQLite database, and ran the real `CreateBackups` migration. The
classes were not modified, stubbed or reimplemented; only `App` was replaced with
a value object holding `VHOSTS_ROOT`, and the app list was read out of the
manager's own production database read-only. Ruby was
`/opt/rbenv/versions/3.3.8/bin/ruby` with `GEM_PATH` pointed at the manager's
`vendor/bundle-rbenv/ruby/3.3.0`. The harness is left on the server at
`/var/backups/ltvb/_harness2` with a README; it is safe to delete once
`rake backup:run` is available on the deployed checkout.

Once the code is deployed, `rake backup:run` is the same code path and none of
this is needed.
