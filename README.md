# media-server

NixOS configuration for **ahiru** - a Raspberry Pi 4 home server running at [ahiru.pl](https://ahiru.pl).

## Services

| Service | Port | Description |
|---------|------|-------------|
| **nginx** | 80, 443 | Reverse proxy with Let's Encrypt |
| **Samba** | 445 | Windows file sharing |
| **NFS** | 2049 | Network filesystem for LAN |
| **rtorrent** | 50000 | Torrent client |
| **Flood** | 3000 | Torrent web UI (`media.ahiru.pl/torrents`) |
| **Calibre-web** | 8083 | Ebook library (`media.ahiru.pl/books`) |
| **Radicale** | 5232 | CalDAV calendar (`media.ahiru.pl/radicale/`) |
| **myMPD** | 8080 | Music player (`media.ahiru.pl/music`) |
| **MPD HTTP** | 8030 | Music streaming |
| **git-shell** | 22 | SSH git hosting (`git@git.ahiru.pl:repo.git`) |
| **msmtp** | - | Outbound email via Migadu |

## Structure

```
.
├── flake.nix              # Flake entry point
├── hosts/
│   └── ahiru/
│       ├── default.nix    # Full host configuration
│       ├── base.nix       # Minimal boot config
│       └── hardware.nix   # Pi-specific hardware
├── modules/
│   ├── common/
│   │   ├── networking.nix # Firewall, DNS
│   │   ├── users.nix      # User accounts + SSH key gen
│   │   ├── security.nix   # Hardening
│   │   └── first-boot-install.nix  # HDD migration
│   └── services/
│       ├── nginx.nix      # Reverse proxy + htpasswd
│       ├── storage.nix    # Samba + NFS
│       ├── torrent.nix    # rtorrent + Flood
│       ├── media.nix      # Calibre, MPD, myMPD
│       ├── calendar.nix   # Radicale
│       ├── git.nix        # git-shell SSH hosting
│       ├── dns.nix        # Blocky DNS
│       ├── websites.nix   # Hugo blog auto-deploy
│       ├── mail.nix       # msmtp outbound mail
│       ├── backup.nix     # Filen cloud backup (rclone)
│       ├── mcp.nix        # MCP server
│       ├── updates.nix    # Update notification emails
│       └── monitoring.nix # Health alerts (disk, temp, services)
├── secrets/               # Local secrets (gitignored)
│   ├── mail.yaml          # SMTP credentials
│   ├── filen.yaml         # Filen cloud credentials
│   ├── updates.yaml       # Update notification recipient
│   ├── monitoring.yaml    # Health alert config
│   └── htpasswd.yaml      # HTTP Basic Auth users
├── deploy-secrets.sh      # Deploy all secrets to Pi
└── static/                # Static files (media portal, theme patches)
```

## Usage

On the Pi:

```bash
cd ~/nixos
git pull
sudo nixos-rebuild switch --flake .#ahiru
```

From your Mac:

```bash
# Copy changed files and rebuild
scp modules/services/foo.nix dan@ahiru.pl:~/nixos/modules/services/
ssh dan@ahiru.pl "cd ~/nixos && sudo nixos-rebuild switch --flake .#ahiru"
```

## Initial Setup

The Pi boots from SD card (`/boot/firmware`) but runs root from HDD (`/dev/sda1`).

### 1. Build base SD image

Build the minimal base image (requires Linux or aarch64 system):

```bash
nix build '.#images.ahiru-base'
```

### 2. Flash to SD card

```bash
zstd -d result/sd-image/*.img.zst -o nixos.img
sudo dd if=nixos.img of=/dev/sdX bs=4M status=progress
```

### 3. Prepare HDD

Ensure HDD is connected with partition layout:

- `sda1` (30GB) - will be formatted as NIXOS_ROOT
- `sda2` (rest) - data partition (untouched)

### 4. Boot and migrate to HDD

Boot the Pi and SSH in:

```bash
ssh dan@<pi-ip>
```

Manually trigger the HDD migration:

```bash
sudo systemctl start hdd-install
```

This will format `sda1`, copy the system, and reboot into HDD root.

### 5. Add SSH key to GitHub

After reboot, the system generates an SSH key and displays it:

```text
==============================================
  SSH KEY GENERATED - ADD TO GITHUB
==============================================

ssh-ed25519 AAAAC3... dan@ahiru

Add this key at: https://github.com/settings/ssh/new
==============================================
```

If you miss it, view with: `cat ~/.ssh/id_ed25519.pub`

### 6. Clone and rebuild

```bash
git clone git@github.com:mruwnik/media-server.git ~/nixos
cd ~/nixos
sudo nixos-rebuild switch --flake .#ahiru
```

### Customization

To use a different primary username, edit `modules/common/users.nix` and change the `primaryUser` block before building the base image.

## Major NixOS Version Upgrades

Upgrading nixpkgs to a new stable channel (e.g. `nixos-24.11` → `nixos-25.11`) requires
building the kernel from source, since `raspberry-pi-nix` packages aren't in the binary cache.

The Pi 4's 30GB root partition is too small for a kernel build with debug symbols (~15GB temp
files), and `/tmp` is a 1.9GB tmpfs. You need to temporarily redirect build temp files to the
data partition:

```bash
# 1. Update flake.nix to the new channel
sed -i 's|nixos-24.11|nixos-25.11|' flake.nix

# 2. Update flake inputs
nix flake update

# 3. Free up nix store space (old generations)
sudo nix-collect-garbage -d

# 4. Bind mount /tmp to the data partition (1.6TB headroom)
sudo mkdir -p /media/data/tmp-nix
sudo mount --bind /media/data/tmp-nix /tmp

# 5. Build with sandbox disabled and limited parallelism to avoid OOM
sudo TMPDIR=/media/data/tmp-nix NIX_REMOTE='' \
  nix --extra-experimental-features 'nix-command flakes' \
  build '.#nixosConfigurations.ahiru.config.system.build.toplevel' \
  --no-link --print-out-paths --max-jobs 1 --cores 2 --option sandbox false

# 6. Apply the built system
sudo nixos-rebuild switch --flake .#ahiru

# 7. Clean up
sudo umount /tmp
sudo rm -rf /media/data/tmp-nix
```

The kernel build takes 4-6 hours on a Pi 4 at `-j2`. Run in `tmux` or `nohup` — an SSH
drop will kill the build otherwise.

**Common issues:**

- **Renamed packages** (e.g. `mpc-cli` → `mpc` in 25.11) — `nixos-rebuild` will error
  with clear messages.
- **API incompatibilities** with `raspberry-pi-nix` — the libcamera fork used by
  raspberry-pi-nix may lag behind nixpkgs. The pipewire libcamera plugin is disabled
  via overlay in `hosts/ahiru/base.nix` for this reason.
- **OOM** — don't use `--max-jobs` > 1 on a 4GB Pi for kernel builds.
- **Step 5 builds the closure without applying** — if it succeeds, step 6 (`nixos-rebuild
  switch`) will reuse the cached kernel and only build the remaining derivations.

## Secrets

Secrets are stored locally in `secrets/` and gitignored. They must be manually copied to the Pi.

### 1. Create secret files

```yaml
# secrets/filen.yaml - Filen cloud backup
filen_user: "your-email@example.com"
filen_password: "your-password"
```

```yaml
# secrets/mail.yaml - Outbound email (Migadu SMTP)
msmtp_user: "your-email@example.com"
msmtp_password: "your-password"
```

```yaml
# secrets/updates.yaml - Update notification recipient
notify_email: "your-email@example.com"
```

```yaml
# secrets/monitoring.yaml - Health alert config
notify_email: "your-email@example.com"
disk_threshold: 90      # Alert when disk > 90% full
temp_threshold: 70      # Alert when CPU > 70°C
memory_threshold: 90    # Alert when RAM > 90% used
```

```yaml
# secrets/htpasswd.yaml - HTTP Basic Auth users
# Passwords starting with $ are pre-hashed, others are hashed at activation
# Last user is used for automated health check tests
users:
  - username: "dan"
    password: "$apr1$..."  # pre-hashed
  - username: "test"
    password: "testpass123"  # plain text, will be hashed
```

### 2. Deploy secrets

```bash
./deploy-secrets.sh
```

This copies all secrets to the Pi and generates `/etc/shared-htpasswd` from htpasswd.yaml.

### 3. Rebuild

```bash
ssh dan@ahiru.pl "cd ~/nixos && sudo nixos-rebuild switch --flake .#ahiru"
```

This generates `/etc/msmtprc` from mail secrets.

### 4. Initialize services

```bash
# Initialize Filen sync (first time only - installs CLI and sets up)
ssh dan@ahiru.pl "sudo systemctl start filen-init"
```

### 5. Verify

```bash
# Check Filen sync status
ssh dan@ahiru.pl "sudo systemctl status filen-sync"

# Test outbound email
ssh dan@ahiru.pl "echo 'Test' | mail -s 'Test' your@email.com"
```
