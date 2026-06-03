# ahiru test battery

Bash health checks for the components on the Pi, plus a split-out notifier.
Modelled on `../../maip-server/provision/monitoring`: small composable check
scripts under `checks/`, a `diagnostics.sh` that runs them all, and a `notify.sh`
that delivers alerts.

**Output contract:** the human report goes to **stderr**; **stdout carries only
the failure lines** (empty when healthy). So any checker (or subset) pipes
straight into the notifier:

```sh
diagnostics.sh | notify.sh "ahiru health"
```

## Layout

```
tests/
  lib.sh            helpers (check_http/check_up/check_content/check_ctype/check_cmd),
                    coloured PASS/FAIL/SKIP, -u parsing, finish (failure payload → stdout)
  checks/
    systemd.sh      services active + no failed units + scheduled timers armed
    calibre.sh      library populated, covers render, write access (regression guards)
    media.sh        mympd, flood, radicale (PROPFIND), mcp (OAuth metadata)
    mpd.sh          control port :6600 + HTTP stream :8030
    torrent.sh      rtorrent rpc socket
    backups.sh      filen-sync timer armed + last run success + recent
    host.sh         disk usage + under-voltage/throttling
    public.sh       blog/portal/auth-gate via the real domains (DNS+TLS)  [takes -u]
  diagnostics.sh    runs every checks/*.sh, aggregates, prints OVERALL verdict
  external.sh       laptop entrypoint → checks/public.sh
  notify.sh         reads stdin, sends to email (msmtp) + Discord; no-op on empty
```

Each `checks/*.sh` is standalone and ends with `finish`, so it can be run alone
or in any combination.

## Usage

```bash
# Public surface, from your laptop:
./tests/external.sh [-u USER:PASS]

# Full checker, on the Pi:
ssh ahiru.pl 'cd ~/nixos && ./tests/diagnostics.sh [-u USER:PASS]'

# Check + alert (silent unless something failed):
ssh ahiru.pl 'cd ~/nixos && ./tests/diagnostics.sh | ./tests/notify.sh "ahiru health"'

# A SUBSET (e.g. what an hourly monitor might run):
ssh ahiru.pl 'cd ~/nixos && { ./tests/checks/systemd.sh; ./tests/checks/backups.sh; } | ./tests/notify.sh "ahiru hourly"'
```

`-u USER:PASS` is the shared basic-auth credential (`/etc/shared-htpasswd`); it
enables the authenticated route checks. Nothing is stored — pass it only when
you want those checks.

## Notes

- `notify.sh` takes the email from `$NOTIFY_EMAIL`/`$MAILTO`, else `notify_email`
  in `/etc/monitoring-config`; Discord from `$DISCORD_WEBHOOK_URL` or
  `/etc/ahiru-discord-webhook`. Each channel self-guards and is skipped if
  unconfigured.
- `calibre.sh`'s write check drops to the `calibre` user (needs passwordless
  `sudo`; `SKIP`s otherwise). Covers/library/language checks guard the bugs
  fixed in `6aade67`.
- `mpd.sh` expects `:8030` to be streaming — it `FAIL`s when nothing is playing.
- **Designed for reuse by `monitoring.nix`:** its hourly health-check can be
  repointed at a subset of `checks/*.sh` piped to `notify.sh`, replacing its
  inline alerting + the old `/root/test-services.sh`. (Not wired yet.)
```
