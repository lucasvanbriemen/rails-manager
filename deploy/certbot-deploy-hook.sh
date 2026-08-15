#!/usr/bin/env bash
#
# certbot deploy hook — re-installs a renewed certificate into whatever is
# actually serving it.
#
# Why this exists: certbot renews into /etc/letsencrypt/live/<name>/, but that
# is NOT what Apache serves. Plesk keeps its own copy in its certificate
# repository and the vhost references it by an opaque id. Without this hook a
# renewal succeeds, certbot reports success, and the live site keeps serving the
# OLD certificate until it expires — a silent failure that only surfaces as a
# browser error weeks later.
#
# Install (as root):
#   install -o root -g root -m 0755 deploy/certbot-deploy-hook.sh \
#       /etc/letsencrypt/renewal-hooks/deploy/ltvb-install-cert
#
# certbot sets RENEWED_LINEAGE (path to the live dir) and RENEWED_DOMAINS.
set -euo pipefail

LOG=/var/log/ltvb-cert-deploy.log
ts() { date -u +%FT%TZ; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

lineage="${RENEWED_LINEAGE:?RENEWED_LINEAGE not set — this must run as a certbot deploy hook}"
name="$(basename "$lineage")"

log "renewed lineage=$name domains=${RENEWED_DOMAINS:-?}"

# --- Plesk-served era ------------------------------------------------------
# While Plesk still owns the vhosts, push the renewed material into its
# repository and re-point the domain at it. `--create` on an existing name
# updates it in place, so this is idempotent across renewals.
if command -v plesk >/dev/null 2>&1 && plesk bin site --info "$name" >/dev/null 2>&1; then
  if plesk bin certificate --create "certbot-$name" -domain "$name" \
       -cert-file   "$lineage/cert.pem" \
       -key-file    "$lineage/privkey.pem" \
       -cacert-file "$lineage/chain.pem" >/dev/null 2>&1 \
     && plesk bin site --update "$name" -certificate-name "certbot-$name" >/dev/null 2>&1
  then
    log "installed into Plesk for $name"
  else
    log "WARN: Plesk install FAILED for $name — the site is still serving the old cert"
  fi
fi

# --- post-Plesk era --------------------------------------------------------
# Once nginx owns :443 it reads /etc/letsencrypt directly, so only a reload is
# needed. Reload (never restart) so in-flight requests are not dropped, and only
# if the config is valid — reloading a broken config takes the site down.
if systemctl is-active --quiet ltvb-nginx 2>/dev/null; then
  if nginx -t >/dev/null 2>&1; then
    systemctl reload ltvb-nginx && log "reloaded ltvb-nginx"
  else
    log "WARN: nginx -t failed — refusing to reload"
  fi
fi

# Mail terminates TLS itself and holds the certificate open, so both daemons
# need a nudge or they serve the expired one until their next restart.
for svc in postfix@- dovecot; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    systemctl reload "$svc" 2>/dev/null && log "reloaded $svc" || log "WARN: reload $svc failed"
  fi
done

log "done for $name"
