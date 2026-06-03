# ahiru test battery

Bash smoke tests for the components running on the Pi, plus a split-out
notifier. Modelled on `../../maip-server/provision/monitoring` — same output
contract: the human report goes to **stderr**, while **stdout carries only the
failure lines** (empty when healthy), so a checker pipes straight into the
notifier:

```sh
diagnostics.sh | notify.sh "ahiru health"
```

## Files

| Script           | Where it runs        | What it does |
|------------------|----------------------|--------------|
| `lib.sh`         | sourced              | helpers (`check_http`, `check_up`, `check_content`, `check_ctype`, `check_cmd`), coloured `PASS`/`FAIL`/`SKIP`, and `finish` (prints the failure payload to stdout) |
| `diagnostics.sh` | **on the Pi**        | the full checker: systemd units, no failed units, calibre library/covers/write (regression guards), mympd/flood/radicale/mcp upstreams, MPD control port + HTTP stream, rtorrent socket, disk, under-voltage — **then** the public-domain checks from `external.sh` (hairpin via the real domains) |
| `external.sh`    | your laptop (or sourced) | public surface only: blog/404/MCP discovery, portal, `/books·/music·/torrents` auth gate (401), optional authed routes. Defines `external_checks` that `diagnostics.sh` reuses |
| `notify.sh`      | the Pi (cron/manual) | reads a message on stdin and sends it to email (msmtp) + Discord; **no-op on empty stdin** |

## Usage

```bash
# Public surface, from your laptop:
./tests/external.sh
./tests/external.sh -u USER:PASS          # also exercise authenticated routes

# Full checker, on the Pi:
ssh ahiru.pl 'cd ~/nixos && ./tests/diagnostics.sh'
ssh ahiru.pl 'cd ~/nixos && ./tests/diagnostics.sh -u USER:PASS'

# Check + alert (silent unless something failed):
ssh ahiru.pl 'cd ~/nixos && ./tests/diagnostics.sh | ./tests/notify.sh "ahiru health"'
```

## Notes

- `notify.sh` takes the alert email from `$NOTIFY_EMAIL`/`$MAILTO`, else
  `notify_email` in `/etc/monitoring-config` (the file the health-check already
  uses); Discord from `$DISCORD_WEBHOOK_URL` or `/etc/ahiru-discord-webhook`.
  Each channel self-guards and is skipped if unconfigured.
- The calibre **write-access** check drops to the `calibre` user and needs
  passwordless `sudo`; it `SKIP`s otherwise.
- Covers and library-non-empty are regression guards for the two calibre-web
  bugs fixed in `6aade67` (srcset/sub_filter; language filter).
- `monitoring.nix`'s hourly health-check still has its own inline alerting and
  calls the old `/root/test-services.sh`. It can be repointed at
  `diagnostics.sh | notify.sh` — not done here to avoid changing the live alert
  path without a heads-up.
