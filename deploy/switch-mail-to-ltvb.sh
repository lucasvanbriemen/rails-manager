#!/usr/bin/env bash
#
# Phase 11 (second half) — move Postfix off Plesk's delivery agent and SASL.
#
# Dovecot is ALREADY migrated: it authenticates from /etc/dovecot/ltvb/passwd
# (passdb + userdb) and exposes both sockets Postfix needs. All nine mailbox
# digests were migrated from the existing passwords and verified 9/9, so no mail
# client needs reconfiguring. This script does the Postfix half.
#
# WHAT CHANGES
#   virtual_mailbox_domains/maps, virtual_alias_maps -> plaintext hash maps in
#     /etc/postfix/ltvb/ (Plesk's are Berkeley DB with no plaintext source)
#   virtual_transport = plesk_virtual  -> lmtp:unix:private/dovecot-lmtp
#   smtpd_sasl_type   = cyrus          -> dovecot
#
# WHY IT IS THE SHARP EDGE
# `plesk_virtual` and `plesk_saslauthd` die together with Plesk, and when
# delivery fails here Postfix does not queue — it BOUNCES. So this must be
# proven working BEFORE Plesk is removed, not during.
#
# Everything is reversible with `--rollback`: main.cf is restored from the
# snapshot taken here and Postfix reloaded. Plesk's own maps are never touched.
#
# Usage:  ./switch-mail-to-ltvb.sh --check     # preconditions only
#         ./switch-mail-to-ltvb.sh             # do it
#         ./switch-mail-to-ltvb.sh --rollback  # undo it
set -uo pipefail

STAGED=/root/mail-staged
MAPDIR=/etc/postfix/ltvb
SNAP=/root/ltvb-phase0-backup/mail-switch
TEST_BOX=ntfy@ltvb.nl
TEST_MAILDIR=/var/qmail/mailnames/ltvb.nl/ntfy/Maildir

say() { printf '\n=== %s ===\n' "$*"; }

# Delivers a message and returns 0 only if a new file lands in the Maildir.
# Counting files is the only honest check: Postfix reports "sent" for a handoff
# to a transport that later discards the message.
delivers() {
  local before after
  before=$(find "$TEST_MAILDIR" -type f 2>/dev/null | wc -l)
  printf 'From: postmaster@ltvb.nl\nTo: %s\nSubject: mail path check\n\nx\n' "$TEST_BOX" \
    | sendmail -f postmaster@ltvb.nl "$TEST_BOX"
  sleep 8
  after=$(find "$TEST_MAILDIR" -type f 2>/dev/null | wc -l)
  [[ "$after" -gt "$before" ]]
}

preflight() {
  local fail=0

  say "1. Dovecot provides both sockets"
  for s in auth dovecot-lmtp; do
    if [[ -S "/var/spool/postfix/private/$s" ]]; then echo "  OK   $s"
    else echo "  MISSING $s — check 'doveconf protocols' includes lmtp"; fail=1; fi
  done

  say "2. every mailbox authenticates from the passwd-file"
  local n; n=$(grep -cv '^#' /etc/dovecot/ltvb/passwd 2>/dev/null || echo 0)
  echo "  $n entries in /etc/dovecot/ltvb/passwd"
  [[ "$n" -ge 9 ]] || { echo "  too few — the userdb must cover every deliverable mailbox"; fail=1; }

  say "3. rendered maps exist"
  for m in virtual_domains vmailbox virtual; do
    [[ -s "$STAGED/$m" ]] || { echo "  MISSING $STAGED/$m — re-render with MailConfig.render_all"; fail=1; }
  done
  echo "  done"

  say "4. mail delivers RIGHT NOW (so a later failure is attributable)"
  if delivers; then echo "  OK — baseline delivery works"; else echo "  FAIL — mail is already broken, fix that first"; fail=1; fi

  return $fail
}

case "${1:-}" in
  --check)
    preflight && { say "PREFLIGHT PASSED"; exit 0; }
    say "PREFLIGHT FAILED"; exit 1 ;;

  --rollback)
    say "ROLLBACK — restoring Plesk delivery"
    [[ -f "$SNAP/main.cf" ]] || { echo "no snapshot at $SNAP/main.cf"; exit 1; }
    cp -a "$SNAP/main.cf" /etc/postfix/main.cf
    postfix check && systemctl reload postfix
    sleep 3
    delivers && echo "  delivery restored" || echo "  STILL BROKEN — investigate before leaving this"
    exit 0 ;;
esac

preflight || { say "PREFLIGHT FAILED — refusing to switch"; exit 1; }

say "snapshot"
mkdir -p "$SNAP"; cp -a /etc/postfix/main.cf "$SNAP/main.cf"
postconf -n > "$SNAP/postconf-n.before"
echo "  $SNAP/main.cf"

say "install the maps"
install -o root -g root -m 0755 -d "$MAPDIR"
for m in virtual_domains vmailbox virtual; do
  install -o root -g root -m 0644 "$STAGED/$m" "$MAPDIR/$m"
  postmap "$MAPDIR/$m"
  echo "  $m ($(grep -cv '^#' "$MAPDIR/$m") entries)"
done

say "switch Postfix"
# Applied as individual postconf calls rather than appending the fragment, so
# each setting REPLACES its Plesk value instead of being shadowed by one.
postconf -e "virtual_mailbox_domains = hash:$MAPDIR/virtual_domains"
postconf -e "virtual_mailbox_maps = hash:$MAPDIR/vmailbox"
postconf -e "virtual_alias_maps = hash:$MAPDIR/virtual"
postconf -e "virtual_mailbox_base = /var/qmail/mailnames"
postconf -e "virtual_uid_maps = static:30"
postconf -e "virtual_gid_maps = static:31"
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"

if ! postfix check; then
  say "postfix check failed — reverting"
  cp -a "$SNAP/main.cf" /etc/postfix/main.cf; systemctl reload postfix; exit 1
fi
systemctl reload postfix
sleep 4

say "VERIFY"
ok=1
delivers && echo "  inbound delivery: OK" || { echo "  inbound delivery: FAILED"; ok=0; }
systemctl is-active --quiet postfix@- && echo "  postfix: active" || { echo "  postfix: DOWN"; ok=0; }
q=$(mailq 2>/dev/null | tail -1); echo "  queue: $q"

if (( ! ok )); then
  say "ROLLING BACK"
  cp -a "$SNAP/main.cf" /etc/postfix/main.cf; systemctl reload postfix; sleep 3
  delivers && echo "  delivery restored" || echo "  STILL BROKEN — investigate now"
  exit 1
fi

say "MAIL IS OFF PLESK"
echo "  Send a real message from an external account to each of ltvb.nl,"
echo "  lucasvanbriemen.nl and voordezorgmanagement.nl and confirm it arrives,"
echo "  and check one IMAP client still syncs, BEFORE removing Plesk."
echo "  Rollback: $0 --rollback"
