# Migration Data

Configuration and data extracted from the current Debian/OMV system.
Each subfolder contains the relevant files and a README explaining migration steps.

## Structure

| Folder | Service | Key Files |
|--------|---------|-----------|
| [nginx/](nginx/) | Reverse proxy, SSL | htpasswd, vhost configs, www/ |
| [samba/](samba/) | Windows file sharing | smb.conf |
| [nfs/](nfs/) | NFS exports | exports |
| [rtorrent/](rtorrent/) | Torrents | rtorrent.rc |
| [calibre/](calibre/) | Book library | (data on /media/data/Books) |
| [mpd/](mpd/) | Music streaming | (data on /media/data/Music) |
| [radicale/](radicale/) | CalDAV | users list |
| [gitea/](gitea/) | Git hosting | passwords, repos list |
| [cryptpad/](cryptpad/) | Encrypted docs | config.js |
| [dns/](dns/) | Ad-blocking | (migrate to Blocky) |
| [users/](users/) | System users | UID/GID mappings |
| [cron/](cron/) | Scheduled tasks | custom jobs, timers |

## Data Locations (on /media/data - preserved)

These directories stay in place, just need correct permissions:

- `/media/data/Books/` - Calibre library
- `/media/data/Music/` - MPD music
- `/media/data/Films/`, `Anime/`, `Serials/` - Media
- `/media/data/Unsorted/` - Torrent staging + rtorrent session
- `/media/data/calendar/` - Radicale CalDAV data
- `/media/data/git/` - Forgejo repos + data
- `/media/data/cryptpad/` - CryptPad data
- `/media/data/backups/` - User backups

## Sensitive Files (gitignored)

- `nginx/htpasswd` - Basic auth passwords
- `gitea/passwords.txt` - Admin password

## Migration Order (from PLAN.md)

1. Base NixOS (SSH, networking) - **current step**
2. nginx + ACME
3. Samba + NFS (verify data access)
4. Services one at a time
