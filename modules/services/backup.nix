{ config, lib, pkgs, ... }:

{
  # ============================================================
  # Backup - rclone to Filen (WebDAV)
  # ============================================================
  # Daily sync of critical data to Filen cloud storage
  # Local is source of truth - cloud is backup copy

  environment.systemPackages = [ pkgs.rclone ];

  # rclone config file (contains Filen WebDAV credentials)
  # Create manually: rclone config, then copy to this location
  # Or use sops-nix for encrypted secrets
  environment.etc."rclone/rclone.conf" = {
    text = ''
      [filen]
      type = webdav
      url = https://webdav.filen.io
      vendor = other
      # user and pass should be set via environment or sops-nix
      # For now, create /root/.config/rclone/rclone.conf manually
    '';
    mode = "0600";
  };

  # Backup service
  systemd.services.backup-to-filen = {
    description = "Backup critical data to Filen";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      # Use config from home dir (with credentials)
      ExecStart = pkgs.writeShellScript "backup-to-filen" ''
        set -euo pipefail

        RCLONE="${pkgs.rclone}/bin/rclone"
        REMOTE="filen:ahiru-backup"

        echo "Starting backup to Filen..."

        # Backup calendar data (Radicale)
        $RCLONE sync /media/data/calendar $REMOTE/calendar \
          --verbose --stats-one-line

        # Backup git repositories
        $RCLONE sync /media/data/git $REMOTE/git \
          --verbose --stats-one-line

        echo "Backup complete."
      '';

      # Don't fail the timer if backup fails
      SuccessExitStatus = "0 1";

      # Logging
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # Daily backup timer
  systemd.timers.backup-to-filen = {
    description = "Daily backup to Filen";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";  # 3 AM daily
      Persistent = true;  # Run if missed
      RandomizedDelaySec = "30m";  # Spread load
    };
  };
}
