# Mail autodiscovery

Six vhosts hand `/autodiscover/autodiscover.xml`,
`(/.well-known/autoconfig)?/mail/config-v1.1.xml` and `/email.mobileconfig` to
the Plesk panel on `127.0.0.1:8880`. Nothing in this repo answers those paths,
so on the day `sw-cp-serverd` stops, every mail client that auto-configures
stops working — silently, because a client that cannot autodiscover just shows
"could not find settings" and offers a manual form.

Everything below was measured on the live box on 2026-08-15 while 8880 was still
answering. The raw captures are on the server under
`/root/plesk-export/autodiscover/`, one directory per domain, plus
`SUMMARY.tsv` (every request, status and byte count) and `NOTES.txt`.

The affected domains are `djtim.eu`, `ltvb.nl`, `lucasvanbriemen.nl`,
`mos-safeguards.com`, `rijschool-mos.nl` and `voordezorgmanagement.nl` — the six
apex domains, which is also exactly the set with `mailAutodiscovery=1` and
`mailProviderType=local`.

## What Plesk does today

`/usr/local/psa/admin/conf/templates/default/domain/service/mailAutoConfig.php`
generates the same block into all six Apache vhosts:

```apache
RewriteCond %{REQUEST_URI} ^/autodiscover/autodiscover\.xml$ [NC,OR]
RewriteCond %{REQUEST_URI} ^(/\.well-known/autoconfig)?/mail/config\-v1\.1\.xml$ [NC,OR]
RewriteCond %{REQUEST_URI} ^/email\.mobileconfig$ [NC]
RewriteRule ^(.*)$ "http://127.0.0.1:8880/mailconfig/" [P,QSA,L,E=REQUEST_URI:%{REQUEST_URI},E=HOST:%{HTTP_HOST}]
...
<Proxy "http://127.0.0.1:8880/mailconfig/">
    RequestHeader set X-Host "%{HOST}e"
    RequestHeader set X-Request-URI "%{REQUEST_URI}e"
</Proxy>
```

The rewrite collapses all three paths onto `/mailconfig/` and passes the
original request in two headers, so the handler branches on `X-Request-URI`
rather than on the path it was called with.

`/usr/local/psa/admin/htdocs/mailconfig/index.php` is ionCube-encoded, but the
three templates beside it are plaintext (`autoconfig.xml`, `autodiscover.xml`,
`email.mobileconfig`) and were used to confirm the field mapping. Every
substitution is one of `{{HOSTNAME}} {{DISPLAY_NAME}} {{INCOMING_SERVER}}
{{OUTGOING_SERVER}} {{IMAP_PORT}} {{POP3_PORT}} {{SMTP_PORT}} {{INCOMING_SSL}}
{{OUTGOING_SSL}} {{USER_NAME}} {{UUID1}} {{UUID2}}`. There is no logic beyond
lookup and substitution.

## The request contract

| Path | Method | Input | Result |
|---|---|---|---|
| `/mail/config-v1.1.xml` | GET | none | 200 `application/xml` |
| `/.well-known/autoconfig/mail/config-v1.1.xml` | GET | none | 200, byte-identical to the above |
| `/autodiscover/autodiscover.xml` | POST | Outlook request XML | 200 `application/xml` |
| `/autodiscover/autodiscover.xml` | GET | — | **400, empty body** |
| `/email.mobileconfig` | GET | `?emailaddress=<addr>` | 200 `application/x-apple-aspen-config` |
| `/email.mobileconfig` | GET | no parameter | **400, empty body** |

Two things here are easy to get wrong and were only found by probing.

**Autodiscover is a POST, not a GET.** A GET returns 400 with an empty body. The
body Outlook sends, and the one used for the captures, is:

```xml
<?xml version="1.0" encoding="utf-8"?>
<Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/requestschema/2006">
  <Request>
    <EMailAddress>ntfy@ltvb.nl</EMailAddress>
    <AcceptableResponseSchema>http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a</AcceptableResponseSchema>
  </Request>
</Autodiscover>
```

**The address must name a mailbox that really exists.** `POST` with
`test@ltvb.nl` returns 400; the same request with `ntfy@ltvb.nl` returns 200.
Same for `?emailaddress=` on mobileconfig. That makes the endpoint a mailbox
oracle — an anonymous caller can enumerate which addresses exist on the box.
Do not reproduce this behaviour; see "What the replacement should not copy".

The rule bites at domain granularity too. `djtim.eu` and `rijschool-mos.nl` have
zero mailboxes, so they return **400 on all four endpoints**, autoconfig
included. Autodiscovery is already dead for those two domains today, and the
replacement does not have to preserve anything for them.

## The captured settings

All four working domains return the same shape. The only variable is the domain
name itself:

| Setting | Value |
|---|---|
| Incoming host | the domain itself — `ltvb.nl`, not `mail.ltvb.nl` |
| IMAP | 993, `SSL` / `<SSL>on</SSL>` / `IncomingMailServerUseSSL=true` |
| POP3 | 995, `SSL` (autoconfig and autodiscover only; mobileconfig is IMAP-only) |
| Outgoing host | the domain itself |
| SMTP | 465, `SSL` |
| Auth | `password-cleartext` / `AuthRequired=on`, `SPA=off`, `DomainRequired=off` |
| Username | the full email address; autoconfig uses the literal `%EMAILADDRESS%` |

Domains that answer: `ltvb.nl`, `lucasvanbriemen.nl`, `mos-safeguards.com`,
`voordezorgmanagement.nl`.
Domains that 400: `djtim.eu`, `rijschool-mos.nl` (no mailboxes).

The exact response bodies to reproduce are the captures — `autoconfig.xml` and
`autodiscover-POST.xml` per domain — not this table.

## The mobileconfig is signed

This is the part that cannot be reproduced by serving a static file.

`/email.mobileconfig` does not return the plist. It returns **DER PKCS#7
SignedData** wrapping the plist, signed with that domain's own Let's Encrypt
leaf key, with the full chain embedded. `openssl cms -inform DER -verify`
succeeds against the system trust store for all four domains. That is why the
responses are 7.4–8.4 KB where the plist itself is 3.4–3.6 KB.

```
ltvb.nl                  CN=ltvb.nl                  issuer CN=YR2, chain Root YR -> ISRG Root X1
lucasvanbriemen.nl       CN=lucasvanbriemen.nl       issuer CN=YR2, chain Root YR -> ISRG Root X1
mos-safeguards.com       CN=mos-safeguards.com       issuer CN=YE2, chain Root YE -> ISRG Root X2 -> ISRG Root X1
voordezorgmanagement.nl  CN=voordezorgmanagement.nl  issuer CN=YE2, chain Root YE -> ISRG Root X2 -> ISRG Root X1
```

Signing needs the private key at request time. An **unsigned** plist still
installs on iOS and macOS, but the install sheet labels the profile
"Unverified" in red instead of "Verified" in green. Nothing breaks; it looks
alarming.

Response headers worth copying:

```
content-type: application/x-apple-aspen-config; chatset=utf-8
content-disposition: attachment; filename="ntfy.ltvb.nl.mobileconfig"
```

`chatset` is Plesk's typo, recorded for fidelity. Use `charset` in the
replacement. The filename is the address with `@` replaced by `.`.

The plist itself carries two UUIDs (`{{UUID1}}` for the profile, `{{UUID2}}` for
the mail payload) which Plesk regenerates on every request. They should instead
be **stable per address** — a v5 UUID over the address is enough — because iOS
uses `PayloadIdentifier` + `PayloadUUID` to decide whether an install replaces
an existing profile or adds a second copy of the same account. Plesk gets this
wrong today; re-downloading the profile twice gives you the mailbox twice.

## A prerequisite that has nothing to do with HTTP

Autoconfig tells clients to connect to `<domain>:993` with SSL. Right now that
only presents a trusted certificate for two of the four working domains:

```
ltvb.nl                 993/465  CN=ltvb.nl                 (SAN ltvb.nl, mail., webmail., www.)
lucasvanbriemen.nl      993/465  CN=lucasvanbriemen.nl      (SAN lucasvanbriemen.nl, mail., webmail., www.)
mos-safeguards.com      993/465  CN=Plesk, O=Plesk          self-signed
voordezorgmanagement.nl 993/465  CN=Plesk, O=Plesk          self-signed
djtim.eu                993/465  CN=Plesk, O=Plesk          self-signed
rijschool-mos.nl        993/465  CN=Plesk, O=Plesk          self-signed
```

So for `mos-safeguards.com` and `voordezorgmanagement.nl` the settings we hand
out today lead straight to a certificate warning. Anyone using those two
mailboxes has already clicked through it.

Worse for the cutover: dovecot's four SNI blocks
(`/etc/dovecot/conf.d/14-plesk-sni-*.conf`) read their certificates from
`/opt/psa/var/certificates/`, which is Plesk's own store and is deleted with the
panel. Postfix reads `tls_server_sni_maps = hash:/var/spool/postfix/plesk/certs`
— also Plesk's. **Repointing dovecot and postfix at `/etc/letsencrypt/live/` is
a prerequisite for autodiscovery being worth restoring at all**, and it is
outside this document's scope. Note while you are there that the certbot
lineages are all single-SAN (`DNS:ltvb.nl` only — no `mail.`, no `webmail.`, no
`www.`), so `mail.lucasvanbriemen.nl` has no lineage to point at even though
dovecot serves it today. See `deploy/WEBMAIL.md`, which covers the same gap.

## Replacement options

### Option A — static XML per domain, served by nginx

Render three files per mail domain into `/etc/ltvb/mailconfig/<domain>/` at the
same time the vhost is rendered, and add a snippet to the six apex vhosts:

```erb
# Mail clients autoconfigure against fixed paths on the mail domain itself.
# Static because the answer only depends on the domain, never on the caller —
# so the path is rendered literally per server block rather than built from
# $host, which would make one bad Host header select another domain's file.
location = /mail/config-v1.1.xml                        { alias /etc/ltvb/mailconfig/<%= fqdn %>/autoconfig.xml;   default_type application/xml; }
location = /.well-known/autoconfig/mail/config-v1.1.xml { alias /etc/ltvb/mailconfig/<%= fqdn %>/autoconfig.xml;   default_type application/xml; }
location = /autodiscover/autodiscover.xml               { alias /etc/ltvb/mailconfig/<%= fqdn %>/autodiscover.xml; default_type application/xml; }
```

Cost: near zero, and it is the same shape as the existing `_acme.conf.erb`
snippet. `NginxConfig` has no free-text config field by design, so this becomes
a fourth typed field (or an unconditional include for apex mail domains) rather
than something an App record can inject.

Two things it cannot do:

- **Autodiscover's `<DisplayName>` and `<LoginName>` echo the requested
  address.** A static file has to hardcode something. `%EMAILADDRESS%` is a
  Thunderbird convention that Outlook does not understand, so the honest static
  answer is to omit `<User><DisplayName>` and set `<LoginName>` to nothing,
  letting Outlook fall back to the address the user typed. That works in current
  Outlook but is a real behaviour change.
- **No signed mobileconfig.** Serve the unsigned plist and accept the
  "Unverified" banner, or drop `/email.mobileconfig` entirely.

Static also means the file goes stale if a mail hostname or port ever changes,
with nothing to notice.

### Option B — a responder in the manager

A controller on the six apex hostnames answering the three paths, rendering from
the `MailDomain` records the import already creates.

Cost: routing has to work per-hostname on domains whose apex is a static site
or a PHP app, so it is a location block proxying to the manager on each of the
six vhosts — more moving parts than Option A, and it puts the manager on the
critical path for a mail client's first-run experience.

What it buys:

- Autodiscover can echo the requested address properly, matching today exactly.
- A signed mobileconfig is possible: read `/etc/letsencrypt/live/<domain>/` and
  sign with OpenSSL's CMS API. This needs the manager to read a private key,
  which today it deliberately cannot — so it means a new agent verb
  (`sign_mobileconfig`, taking the domain and the plist, returning DER) rather
  than handing the manager a key. That is a real addition to the privilege
  boundary for a green "Verified" badge.
- Settings follow the records, so they cannot go stale.

### Option C — serve nothing

Defensible and cheap. Four domains have working autodiscovery, and between them
they have nine mailboxes and four Roundcube accounts. Two of the four domains
hand out settings that produce a certificate warning anyway.

The cost is not "no autodiscovery" but "a client that is *already configured*
keeps working, and a new device needs the settings typed in by hand". Nothing
re-checks autodiscovery after setup, so no working mail client breaks the day
Plesk is removed. What breaks is the next phone.

If you take this option, do it deliberately: the settings that would have to be
typed are IMAP `<domain>:993` SSL, SMTP `<domain>:465` SSL, username = full
address. Write them down somewhere the account owners can find them.

## Recommendation

**Option A, minus mobileconfig.** Autoconfig is the broadest endpoint —
Thunderbird defined it and most third-party desktop and Android clients follow
it — it is a pure function of the domain, and a static file is exactly the right
amount of machinery. Autodiscover as a static file covers Outlook with the one
caveat above. Between them the two cover every client that autodiscovers at all;
Apple Mail is the gap, and it is the one that wanted the signed profile. Drop `/email.mobileconfig`: it is the only endpoint that
needs a private key, its Plesk implementation duplicates accounts on
re-download, and it requires the user to already know their address to construct
the URL — which means somebody has already told them the settings.

Revisit Option B only if a signed profile turns out to be wanted, and treat the
new agent verb as the actual cost of that decision.

## What the replacement should not copy

- **The mailbox oracle.** Answer for any address at a domain we host. There is
  no reason for `/autodiscover/autodiscover.xml` to distinguish an existing
  mailbox from a typo, and doing so leaks the mailbox list to anonymous callers.
- **The `chatset=utf-8` typo.**
- **Per-request random UUIDs** in the mobileconfig, if it is implemented at all.
- **POP3.** It is advertised today, but every mailbox on the box is IMAP; the
  mobileconfig template already omits POP3. Advertising it invites a client to
  pick the one protocol that will delete mail off the server.

## Reproducing the capture

```bash
# still works only while sw-cp-serverd is alive
bash /root/plesk-export/autodiscover/capture.sh

# single endpoint, by hand
curl https://ltvb.nl/mail/config-v1.1.xml
curl -X POST -H 'Content-Type: text/xml' \
     --data-binary @/root/plesk-export/autodiscover/ltvb.nl/autodiscover-POST.request.xml \
     https://ltvb.nl/autodiscover/autodiscover.xml
curl 'https://ltvb.nl/email.mobileconfig?emailaddress=ntfy@ltvb.nl' \
  | openssl smime -verify -inform DER -noverify
```
