#!/usr/bin/env bash
#
# Phase 7 — move :80/:443 from Apache to nginx.
#
# This is the one step where every site changes web server at once, so the whole
# design is: prove it on 9080/9443 first, make the switch two systemctl calls,
# and keep Apache's config untouched so rolling back is starting it again.
#
# PRECONDITIONS (checked below, not assumed)
#   * ltvb-nginx is serving every live hostname on 9443 and the acceptance
#     matrix is clean — same status and same body as Apache, allowing for the
#     staging port appearing in generated absolute URLs and per-request CSRF
#     tokens, neither of which survives the switch to :443.
#   * Every Rails app answers on 9443, i.e. Phase 6 (Puma) is done. Before that
#     they 502, because nginx proxies to a socket nothing is listening on.
#   * Certificates are the certbot lineages under /etc/letsencrypt/live, not
#     Plesk's copies. Already true: all 20 expire 2026-11-13.
#
# ROLLBACK is `--rollback`: stop nginx, start Apache. Under 30 seconds, and
# Apache's vhosts were never edited, so there is nothing to restore.
#
# Usage:  ./cutover-to-nginx.sh --check      # preconditions only, changes nothing
#         ./cutover-to-nginx.sh              # do it
#         ./cutover-to-nginx.sh --rollback   # undo it
set -uo pipefail

NGINX_CONF=/etc/ltvb/nginx/nginx.conf
NGINX_BIN=/usr/local/sbin/ltvb-nginx
SITES=/etc/ltvb/nginx/sites
STAGING_HTTP=9080
STAGING_HTTPS=9443

say() { printf '\n=== %s ===\n' "$*"; }
hosts() { ls /var/www/vhosts/system/; }

# 4xx counts as healthy: aio has no root route, several sites redirect to SSO.
# What is being proven is that something answered, not that it answered 200 —
# a dead upstream gives 502 and a missing vhost gives the default server.
probe() { # probe <host> <port>
  curl -sS -o /dev/null -w '%{http_code}' "https://$1:$2/" --resolve "$1:$2:127.0.0.1" --max-time 20 -k 2>/dev/null
}
probe_live() {
  curl -sS -o /dev/null -w '%{http_code}' "https://$1/" --max-time 20 -k 2>/dev/null
}

preflight() {
  local fail=0

  say "1. nginx config parses"
  if $NGINX_BIN -t -c $NGINX_CONF >/dev/null 2>&1; then echo "  OK"; else
    $NGINX_BIN -t -c $NGINX_CONF 2>&1 | tail -3; fail=1; fi

  say "2. every live hostname has a rendered site file"
  for h in $(hosts); do
    [[ -f "$SITES/$h.conf" ]] || { echo "  MISSING $h"; fail=1; }
  done
  echo "  $(ls $SITES/*.conf 2>/dev/null | wc -l) rendered, $(hosts | wc -l) live hostnames"

  say "3. staging answers for every hostname (no 502s — Puma must be up)"
  for h in $(hosts); do
    local c; c=$(probe "$h" $STAGING_HTTPS)
    case "$c" in
      2*|3*|4*) ;;
      502) echo "  502  $h — upstream not running (Phase 6 incomplete?)"; fail=1 ;;
      *)   echo "  $c  $h"; fail=1 ;;
    esac
  done
  echo "  done"

  say "4. staging matches live, host by host"
  # Three things legitimately differ between the two stacks and must be
  # normalised away, or every dynamic site reads as a failure:
  #   * the staging port in generated absolute URLs — both literally (":9443")
  #     and percent-encoded ("%3A9443"), which appears inside redirect params;
  #   * per-request CSRF tokens and session ids;
  #   * genuinely random content. mos-safeguards.com picks a testimonial per
  #     request, so two fetches of the SAME server disagree. Compare Apache with
  #     itself first and skip any host that cannot even match itself — that is
  #     the only honest way to tell "dynamic" from "broken".
  local differ=0
  for h in $(hosts); do
    local a b ha hb self
    a=$(probe_live "$h"); b=$(probe "$h" $STAGING_HTTPS)
    norm() { sed -e "s/:$STAGING_HTTPS//g" -e "s/%3A$STAGING_HTTPS//gI" -E -e 's/[A-Za-z0-9_-]{32,}/T/g' | md5sum | cut -c1-8; }
    ha=$(curl -sS "https://$h/" --max-time 20 -k 2>/dev/null | norm)
    self=$(curl -sS "https://$h/" --max-time 20 -k 2>/dev/null | norm)
    hb=$(curl -sS "https://$h:$STAGING_HTTPS/" --resolve "$h:$STAGING_HTTPS:127.0.0.1" --max-time 20 -k 2>/dev/null | norm)

    # Bodies are only compared for 2xx/3xx. On a 4xx/5xx the body is an error
    # page — Apache serves Plesk's /error_docs, nginx serves its built-in — and
    # they will never match. What matters there is that both stacks REFUSE the
    # same request with the same status, not that they apologise identically.
    if [[ "$a" != "$b" ]]; then
      printf "  DIFFER  %-32s apache=%s nginx=%s\n" "$h" "$a" "$b"; differ=$((differ+1)); continue
    fi
    case "$a" in 4*|5*) printf "  status  %-32s %s (error page body not compared)\n" "$h" "$a"; continue ;; esac

    if [[ "$ha" != "$self" ]]; then
      printf "  dynamic %-32s (Apache differs from itself; status only)\n" "$h"; continue
    fi
    [[ "$ha" == "$hb" ]] || { printf "  DIFFER  %-32s same status %s, different body\n" "$h" "$a"; differ=$((differ+1)); }
  done
  echo "  $differ host(s) differ"
  (( differ )) && fail=1

  say "5. certificates come from certbot, not Plesk"
  local plesk; plesk=$(grep -rl "/opt/psa/var/certificates" $SITES/ 2>/dev/null | wc -l)
  if (( plesk )); then echo "  $plesk site(s) still reference Plesk's cert store"; fail=1; else echo "  OK"; fi

  return $fail
}

case "${1:-}" in
  --check)
    preflight && { say "PREFLIGHT PASSED — safe to cut over"; exit 0; }
    say "PREFLIGHT FAILED — do not cut over"; exit 1
    ;;

  --rollback)
    say "ROLLBACK"
    systemctl stop ltvb-nginx
    # Apache's config was never edited, so there is nothing to restore.
    systemctl start apache2
    sleep 5
    for h in $(hosts); do printf "  %-32s %s\n" "$h" "$(probe_live "$h")"; done
    exit 0
    ;;
esac

preflight || { say "PREFLIGHT FAILED — refusing to cut over"; exit 1; }

say "CUTOVER — Apache down, nginx onto :80/:443"
# Apache first: two processes cannot hold :443, and nginx must not be left
# half-bound. Stop, not disable — rollback is `systemctl start apache2`.
systemctl stop apache2
# Rewrite ONLY the port, leaving whatever else is on the line alone. The first
# version of this matched `listen 9443 ssl;` literally, which silently missed
# the one block written as `listen 9443 default_server ssl;` — so the default
# server never moved to :443, every request for that host fell through to the
# alphabetically-first block, and an HSTS-pinned domain served another site's
# certificate. A port rewrite must not care what follows the port.
sed -i -E "s/^([[:space:]]*listen[[:space:]]+(\[::\]:)?)$STAGING_HTTP\b/\1${STAGING_HTTP:+80}/; \
           s/^([[:space:]]*listen[[:space:]]+(\[::\]:)?)$STAGING_HTTPS\b/\1443/" $SITES/*.conf

if ! $NGINX_BIN -t -c $NGINX_CONF >/dev/null 2>&1; then
  say "config broke after rebinding — reverting"
  sed -i -E "s/^([[:space:]]*listen[[:space:]]+(\[::\]:)?)80\b/\1$STAGING_HTTP/; \
             s/^([[:space:]]*listen[[:space:]]+(\[::\]:)?)443\b/\1$STAGING_HTTPS/" $SITES/*.conf
  systemctl start apache2
  exit 1
fi

systemctl restart ltvb-nginx
sleep 6

say "VERIFY"
bad=0
for h in $(hosts); do
  c=$(probe_live "$h")
  case "$c" in 2*|3*|4*) ;; *) printf "  FAIL %-32s %s\n" "$h" "$c"; bad=$((bad+1));; esac
done
echo "  $(( $(hosts | wc -l) - bad ))/$(hosts | wc -l) responding"

if (( bad )); then
  say "ROLLING BACK — $bad host(s) failed"
  systemctl stop ltvb-nginx
  systemctl start apache2
  exit 1
fi

say "CUTOVER COMPLETE"
echo "  Apache is stopped but installed; rollback is ./cutover-to-nginx.sh --rollback"
echo "  Leave it that way for at least a week before removing anything."
