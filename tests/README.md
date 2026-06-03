# ahiru test battery

Bash smoke tests for the components running on the Pi. Most checks run **on the
Pi** (localhost upstreams + systemd + filesystem, no credentials needed); a thin
**external** layer runs **from your laptop** to verify the public-facing surface
(DNS, TLS, the basic-auth gate).

Style follows `../../maip-server/provision/monitoring/tests`: plain bash, a
shared `lib.sh` with coloured `PASS`/`FAIL`/`SKIP` and running counters, exit
non-zero if anything fails.

## Files

| Script         | Where it runs | What it checks |
|----------------|---------------|----------------|
| `lib.sh`       | sourced       | helpers: `check_http`, `check_up`, `check_content`, `check_ctype`, `check_cmd`, `summary` |
| `run-local.sh` | **on the Pi** | systemd units active, no failed units, calibre library non-empty + covers serve as images + write access, mympd/flood/radicale/mcp upstreams, MPD control port + HTTP stream, rtorrent rpc socket, disk usage, under-voltage/throttling |
| `external.sh`  | your laptop   | blog homepage/404, MCP discovery, portal index, `/books` `/music` `/torrents` auth gate (401), optional authed routes |
| `run-all.sh`   | your laptop   | runs `external.sh` locally, then ships `run-local.sh` to the Pi over SSH and runs it |

## Usage

```bash
# Everything, from your laptop (external + on-Pi via SSH):
./tests/run-all.sh
./tests/run-all.sh -u USER:PASS          # also exercise authenticated routes
AHIRU_SSH=192.168.1.50 ./tests/run-all.sh # override SSH host

# Just the public surface:
./tests/external.sh
./tests/external.sh -u USER:PASS

# Just the Pi-side checks (on the Pi, or via ssh):
ssh ahiru.pl 'cd ~/nixos && ./tests/run-local.sh'
```

`run-all.sh` copies `lib.sh` + `run-local.sh` to a temp dir on the Pi before
running, so the Pi's checkout doesn't need to be up to date.

## Notes

- The calibre **write-access** check drops to the `calibre` user and needs
  passwordless `sudo`; it `SKIP`s otherwise.
- The covers and library-non-empty checks are regression guards for the two
  calibre-web bugs fixed in commit `6aade67` (srcset/sub_filter; language filter).
- `USER:PASS` is the shared basic-auth credential (from `/etc/shared-htpasswd`).
  Nothing is stored — pass it on the command line only when you want the authed
  checks.
