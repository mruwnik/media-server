{ config, lib, pkgs, ... }:

# First-boot service to migrate root filesystem from SD card to HDD.
# Does NOT run automatically - must be triggered manually.
#
# To install:  sudo systemctl start hdd-install
# To check:    systemctl status hdd-install

let
  targetDevice = "/dev/sda1";
  targetLabel = "NIXOS_ROOT";
in
{
  systemd.services.hdd-install = {
    description = "Migrate root filesystem to HDD";
    # NOT in wantedBy - must be started manually
    after = [ "local-fs.target" ];

    serviceConfig = {
      Type = "oneshot";
    };

    script = ''
      set -euo pipefail

      echo "=== HDD Install Check ==="

      # Check 1: Are we already booted from HDD?
      current_root=$(findmnt -n -o SOURCE /)
      if [[ "$current_root" == *"${targetLabel}"* ]] || [[ "$current_root" == "${targetDevice}" ]]; then
        echo "Already booted from HDD root. Nothing to do."
        exit 0
      fi
      echo "Currently booted from: $current_root"

      # Check 2: Does target device exist?
      if [[ ! -b ${targetDevice} ]]; then
        echo "ERROR: Target device ${targetDevice} not found!"
        exit 1
      fi
      echo "Target device: ${targetDevice}"

      # Check 3: Does HDD already have a NixOS installation?
      mkdir -p /mnt/hdd-check
      if mount ${targetDevice} /mnt/hdd-check 2>/dev/null; then
        if [[ -d /mnt/hdd-check/nix/store ]]; then
          echo "WARNING: ${targetDevice} already contains a NixOS installation!"
          echo "Contents of /nix/store: $(ls /mnt/hdd-check/nix/store | wc -l) items"
          umount /mnt/hdd-check
          echo ""
          echo "To force reinstall, first wipe the partition:"
          echo "  sudo wipefs -a ${targetDevice}"
          echo "Then run this service again."
          exit 1
        fi
        umount /mnt/hdd-check
      fi
      rmdir /mnt/hdd-check 2>/dev/null || true

      echo ""
      echo "=== Installing to HDD ==="
      echo ""

      echo "Formatting ${targetDevice} as ${targetLabel}..."
      ${pkgs.e2fsprogs}/bin/mkfs.ext4 -F -L ${targetLabel} ${targetDevice}

      echo "Mounting ${targetDevice}..."
      mkdir -p /mnt/hdd-root
      mount ${targetDevice} /mnt/hdd-root

      echo "Copying root filesystem (this may take a few minutes)..."
      ${pkgs.rsync}/bin/rsync -axHAWXS --numeric-ids --info=progress2 \
        --exclude='/mnt/*' \
        --exclude='/tmp/*' \
        --exclude='/run/*' \
        --exclude='/dev/*' \
        --exclude='/proc/*' \
        --exclude='/sys/*' \
        --exclude='/boot/firmware/*' \
        --exclude='/media/*' \
        / /mnt/hdd-root/

      # Create mount points
      mkdir -p /mnt/hdd-root/{mnt,tmp,run,dev,proc,sys,boot/firmware,media/data}

      sync
      umount /mnt/hdd-root

      echo ""
      echo "=== Migration complete! ==="
      echo ""
      echo "Rebooting into HDD root in 5 seconds..."
      echo "(Ctrl+C to cancel)"
      sleep 5
      ${pkgs.systemd}/bin/systemctl reboot
    '';

    path = with pkgs; [ util-linux coreutils findutils ];
  };
}
