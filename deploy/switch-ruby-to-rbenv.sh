#!/usr/bin/env bash
#
# Phase 4 — move the six ltvb.nl Rails apps off Plesk's Ruby onto /opt/rbenv.
#
# WHY THIS IS DELICATE
# All six apps resolve Ruby through ONE symlink:
#   /var/www/vhosts/ltvb.nl/.rbenv/versions/3.3.8 -> /var/lib/rbenv/versions/3.3.8
#                                                 -> /opt/plesk/ruby/3.3.8
# so repointing it switches all six at once. Worse, their native extensions are
# compiled against Plesk's Ruby (built --disable-shared) and will NOT load under
# a different prefix: RubyGems reports "extensions are not built" and Passenger
# fails with "Web application could not be started".
#
# Rebuilding in place is therefore NOT safe: it breaks the app instantly, while
# the old Ruby is still serving it. (Learned the hard way — it took aio.ltvb.nl
# down.) Note that BUNDLE_PATH as an env var does NOT override .bundle/config;
# the config file wins, which is why the pre-build uses BUNDLE_APP_CONFIG.
#
# THE SAFE SEQUENCE (steps 1-2 are already done by the time you run this)
#   1. Build /opt/rbenv/versions/3.3.8 + bundler 2.5.22.                [done]
#   2. Pre-build each app's gems into vendor/bundle-rbenv against it,
#      leaving the live vendor/bundle untouched.                        [done]
#   3. Repoint the symlink. Nothing changes yet: Passenger keeps warm
#      processes on the old Ruby until each app is restarted.
#   4. Per app, swap the bundle directory and restart — that app cold-spawns
#      on the new Ruby with gems built for it. Verify before moving on.
#
# Least-critical app first, SSO last, so a failure is discovered on something
# that matters least and never leaves login.ltvb.nl down.
#
# Usage:  ./switch-ruby-to-rbenv.sh            # do it
#         ./switch-ruby-to-rbenv.sh --rollback # undo it
set -uo pipefail

SYMLINK=/var/www/vhosts/ltvb.nl/.rbenv/versions/3.3.8
OLD_TARGET=/opt/plesk/ruby/3.3.8
NEW_TARGET=/opt/rbenv/versions/3.3.8
WEBSPACE=/var/www/vhosts/ltvb.nl
APPS=(aio.ltvb.nl music.ltvb.nl mail.ltvb.nl git.ltvb.nl apps.ltvb.nl login.ltvb.nl)

say() { printf '\n=== %s ===\n' "$*"; }

# 4xx counts as healthy: aio has no root route and answers 404, and the SSO
# redirects. What we are proving is that Rails answered at all — a Passenger
# spawn failure returns 500 with its own error page.
check() {
  local fqdn="$1" code
  code=$(curl -sS -o /dev/null -w '%{http_code}' "https://$fqdn/" --max-time 25 -k 2>/dev/null)
  case "$code" in 2*|3*|4*) echo "  OK   $fqdn -> $code"; return 0 ;; esac
  echo "  FAIL $fqdn -> $code"; return 1
}

repoint() {
  # rename over the old link is atomic; `ln -sfn` unlinks first and leaves a
  # window where the path does not exist.
  ln -sfn "$1" "$SYMLINK.new" && mv -Tf "$SYMLINK.new" "$SYMLINK"
  chown -h ltvb:psacln "$SYMLINK"
  echo "  symlink -> $(readlink -f "$SYMLINK")"
}

if [[ "${1:-}" == "--rollback" ]]; then
  say "ROLLBACK: restoring Plesk Ruby and the original bundles"
  repoint "$OLD_TARGET"
  for a in "${APPS[@]}"; do
    p="$WEBSPACE/$a"
    if [[ -d "$p/vendor/bundle.plesk" ]]; then
      mv "$p/vendor/bundle" "$p/vendor/bundle-rbenv" 2>/dev/null
      mv "$p/vendor/bundle.plesk" "$p/vendor/bundle"
      echo "  restored $a"
    fi
    touch "$p/tmp/restart.txt"
  done
  sleep 12
  say "verify"; for a in "${APPS[@]}"; do check "$a"; done
  exit 0
fi

say "preflight"
for a in "${APPS[@]}"; do
  [[ -d "$WEBSPACE/$a/vendor/bundle-rbenv/ruby/3.3.0" ]] || {
    echo "  ABORT: $a has no pre-built bundle — run the pre-build first"; exit 1; }
done
"$NEW_TARGET/bin/ruby" -v || { echo "  ABORT: $NEW_TARGET is not usable"; exit 1; }
echo "  all six pre-built, new Ruby usable"

say "step 3 — repoint the shared symlink (warm processes keep serving)"
repoint "$NEW_TARGET"

failed=()
for a in "${APPS[@]}"; do
  say "step 4 — $a"
  p="$WEBSPACE/$a"
  mv "$p/vendor/bundle" "$p/vendor/bundle.plesk" && \
  mv "$p/vendor/bundle-rbenv" "$p/vendor/bundle" || { echo "  ABORT: swap failed"; exit 1; }
  touch "$p/tmp/restart.txt"
  sleep 10
  if ! check "$a"; then
    echo "  reverting $a only, and stopping here"
    mv "$p/vendor/bundle" "$p/vendor/bundle-rbenv"
    mv "$p/vendor/bundle.plesk" "$p/vendor/bundle"
    touch "$p/tmp/restart.txt"
    failed+=("$a")
    break
  fi
done

say "result"
if (( ${#failed[@]} )); then
  echo "  FAILED on ${failed[*]} — that app is reverted, but the symlink still"
  echo "  points at the new Ruby and earlier apps are already swapped."
  echo "  Run with --rollback to put everything back."
  exit 1
fi
echo "  all six on $NEW_TARGET"
echo "  old bundles kept as vendor/bundle.plesk — delete once you are satisfied:"
echo "    for a in ${APPS[*]}; do rm -rf $WEBSPACE/\$a/vendor/bundle.plesk; done"
echo "  /opt/plesk/ruby is still present and is the rollback target; keep it a week."
