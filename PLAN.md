# NixOS Raspberry Pi 4 Home Server Migration

Migrating from Debian/OpenMediaVault to NixOS. Declarative, reproducible, with automatic rollback.

## Target Services

| Service | Purpose | NixOS Module |
|---------|---------|--------------|
| nginx + ACME | Reverse proxy, SSL | `services.nginx`, `security.acme` |
| Samba | Windows file sharing | `services.samba` |
| NFS | Network filesystem (LAN) | `services.nfs.server` |
| rtorrent + Flood | Torrents with web UI | `services.rtorrent`, `services.flood` |
| Calibre-web | Book library | `services.calibre-web` |
| MPD + myMPD | Music + web UI + streaming | `services.mpd` |
| Radicale | CalDAV calendar | `services.radicale` |
| Git (SSH) | Bare repos via SSH | `users.users.git` + git-shell |
| Blocky | DNS ad-blocking | `services.blocky` |
| rclone + Filen | Cloud backup | systemd timer + `pkgs.rclone` |

## Boot Strategy

**USB boot from HDD** - no SD card required.

```
Current layout:
  sda1: 30GB  - unused old root → repurpose for NixOS
  sda2: 4.5TB - data partition  → keep unchanged
  mmcblk0: SD card             → no longer needed

Target:
  /dev/sda1 → / (NixOS root)
  /dev/sda2 → /media/data (existing data)
```

## Implementation Phases

### Phase 0: Enable USB Boot (on current Debian)
```bash
sudo rpi-eeprom-config --edit
# Set BOOT_ORDER=0xf14
```

### Phase 1: Build NixOS Config
1. Create flake with raspberry-pi-nix, sops-nix
2. Configure hardware.nix for USB boot
3. Build image: `nix build '.#images.ahiru'`

### Phase 2: Install
1. Boot NixOS installer from SD (temporary)
2. Mount sda1, run `nixos-install --root /mnt`
3. Reboot into USB

### Phase 3: Services (incremental)
1. nginx + ACME (foundation)
2. Samba + NFS (verify data access)
3. Each remaining service one at a time

## Domain Structure

- `ahiru.pl` - blog (Hugo static site)
- `media.ahiru.pl` - Calibre `/books`, Flood `/torrents`, MPD `/music`, Radicale `/radicale`
- `git.ahiru.pl` - SSH access only (`git@git.ahiru.pl:repo.git`)

## Key Decisions

| Choice | Decision | Rationale |
|--------|----------|-----------|
| Torrent UI | Flood (not ruTorrent) | ruTorrent has NixOS bugs |
| Ad blocking | Blocky (not Pi-hole) | Native module, no containers |
| Git hosting | SSH + git-shell (not Forgejo) | Simple, no web UI needed |
| MPD streaming | httpd output | Built-in, replaces Icecast |
| Boot media | USB HDD | No SD card wear concerns |
| Cloud backup | rclone → Filen (WebDAV) | Daily sync, local is source of truth |

## Files to Create

```
raspberry/
├── flake.nix
├── flake.lock
├── hosts/ahiru/
│   ├── default.nix
│   ├── hardware.nix
│   └── secrets.nix
├── modules/
│   ├── services/
│   │   ├── nginx.nix
│   │   ├── storage.nix      # Samba, NFS
│   │   ├── torrent.nix      # rtorrent, Flood
│   │   ├── media.nix        # MPD, Calibre
│   │   ├── calendar.nix     # Radicale
│   │   ├── git.nix          # git user + SSH
│   │   ├── dns.nix          # Blocky
│   │   └── backup.nix       # rclone → Filen
│   └── common/
│       ├── networking.nix
│       ├── users.nix
│       └── security.nix
└── secrets/
    └── htpasswd.enc
```
