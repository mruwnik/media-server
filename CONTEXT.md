# Current System State

Captured from `ssh pi` on 2026-01-04.

## Hardware

- Raspberry Pi 4 (4GB RAM assumed)
- 5TB USB3 HDD

## Disk Layout

```
NAME        FSTYPE  SIZE      MOUNTPOINT
mmcblk0             15GB      (SD card - current boot)
├─mmcblk0p1 vfat    256MB     /boot
└─mmcblk0p2 ext4    15GB      / (root)

sda                 4.8TB     (USB HDD)
├─sda1      ext4    30GB      /srv/dev-disk-by-uuid-... (old root backup, unused)
└─sda2      ext4    4.5TB     /media/data
```

### Partition UUIDs
- sda1: `b0b6ea33-0881-4c39-a87f-f962c15cd6ad`
- sda2: `1934daec-232f-41f6-b6b8-107923b3fd1e`

## Current Services (from blog posts + inspection)

| Service | Status | Notes |
|---------|--------|-------|
| OpenMediaVault | Running | Base management layer |
| Samba | Running | Public shares |
| NFS | Running | LAN exports |
| rtorrent + ruTorrent | Running | Watch dir at /media/data/Unsorted/.watch/ |
| Calibre | Running | Port 8123 → /books |
| MPD + Icecast | Running | Stream at port 8030 |
| RompR | Running | MPD web UI |
| Radicale | Running | At /radicale |
| Gitea | Running | At git.ahiru.pl |
| Pi-hole | Running | DNS ad-blocking |
| CryptPad | Running | At docs.ahiru.pl |
| nginx | Running | Reverse proxy + certbot SSL |

## Data Directories (/media/data)

```
Films/
Serials/
Anime/
Music/
Books/        (Calibre library)
Unsorted/     (torrent staging, watch dirs)
backups/
  dan/
  nadia/
calendar/     (Radicale data)
git/          (bare repos)
```

## Network

- Domain: ahiru.pl
- Subdomains: git.ahiru.pl, docs.ahiru.pl, media.ahiru.pl
- Public IP from ISP with port forwarding
- Ports: 80, 443, 445 (SMB), 8030 (Icecast)

## Existing Optimizations

Already implemented to reduce SD card wear:
```
folder2ram mounted:
  /var/log
  /var/tmp
  /var/lib/openmediavault/rrd
  /var/spool
  /var/lib/rrdcached
  /var/lib/monit
  /var/cache/samba
```

## NFS Exports (current)

```
/media/data/Films/      → /export/Films
/media/data/Anime/      → /export/Anime
/media/data/Music/      → /export/Music
/media/data/Books/      → /export/Books
/media/data/Serials/    → /export/Serials
/media/data/Unsorted/   → /export/Unsorted
/media/data/backups/dan/    → /export/dan-backup
/media/data/backups/nadia/  → /export/nadia
```

## Known Pain Points (from blog)

1. NFS UID mapping across machines
2. ruTorrent RPC socket permissions
3. Gitea SSH routing (port conflict with router)
4. iOS CalDAV path quirks with Radicale
5. Icecast doesn't work behind nginx reverse proxy
6. System hasn't been updated in a while (OMV version lock)

## Service Users (to recreate)

- calibre
- torrents
- radicale
- git
- cryptpad
