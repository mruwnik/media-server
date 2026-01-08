{ config, lib, pkgs, ... }:

let
  primaryUser = config.ahiru.primaryUser.name;
in
{
  # ============================================================
  # Backup - Filen CLI (native end-to-end encrypted cloud sync)
  # ============================================================
  # Two-way sync for /media/data/backups ↔ /backups on Filen
  # Credentials stored in /etc/filen-secrets (copy secrets/filen.yaml to Pi)

  environment.systemPackages = [ pkgs.nodejs_22 ];

  # Ensure directories exist (primaryUser owns backups and filen working dir)
  systemd.tmpfiles.rules = [
    "d /media/data/backups 0755 ${primaryUser} users -"
    "d /var/lib/filen 0700 ${primaryUser} users -"
  ];

  # Configure Filen at activation (runs as root, sets up for primaryUser)
  system.activationScripts.filen-setup = {
    text = ''
      SECRETS="/etc/filen-secrets"
      FILEN_DIR="/var/lib/filen"

      # Ensure filen directory exists with correct ownership
      mkdir -p "$FILEN_DIR"
      mkdir -p "$FILEN_DIR/.config"
      mkdir -p "$FILEN_DIR/filen-cli"
      chown -R ${primaryUser}:users "$FILEN_DIR"
      chmod 700 "$FILEN_DIR"

      if [ -f "$SECRETS" ]; then
        FILEN_USER=$(${pkgs.yq}/bin/yq -r '.filen_user' "$SECRETS")

        # Create sync pairs config - only backups, two-way sync to /backups
        cat > "$FILEN_DIR/syncPairs.json" << EOF
[
  {
    "local": "/media/data/backups",
    "remote": "/backups",
    "syncMode": "twoWay",
    "alias": "backups"
  }
]
EOF
        chown ${primaryUser}:users "$FILEN_DIR/syncPairs.json"
        chmod 600 "$FILEN_DIR/syncPairs.json"
        echo "Filen configured for $FILEN_USER (running as ${primaryUser})"
      else
        echo "Warning: $SECRETS not found, Filen not configured"
      fi
    '';
  };

  # ============================================================
  # Filen sync service - runs all configured sync pairs
  # ============================================================
  systemd.services.filen-sync = {
    description = "Sync data with Filen cloud";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.nodejs_22 pkgs.bash pkgs.coreutils pkgs.gnused pkgs.gnugrep ];

    serviceConfig = {
      Type = "oneshot";
      User = primaryUser;
      Group = "users";
      WorkingDirectory = "/var/lib/filen";
      ExecStart = pkgs.writeShellScript "filen-sync" ''
        set -euo pipefail

        export PATH="${pkgs.nodejs_22}/bin:$PATH"
        export HOME="/var/lib/filen"
        export FILEN_CLI_DATA_DIR="/var/lib/filen/filen-cli"
        FILEN="/var/lib/filen/node_modules/.bin/filen"

        # Install filen if needed
        if [ ! -x "$FILEN" ]; then
          echo "Installing Filen CLI..."
          cd /var/lib/filen
          ${pkgs.nodejs_22}/bin/npm install @filen/cli
        fi

        # Load credentials as environment variables (Filen CLI auth method)
        if [ -f /etc/filen-secrets ]; then
          export FILEN_EMAIL=$(${pkgs.yq}/bin/yq -r '.filen_user' /etc/filen-secrets)
          export FILEN_PASSWORD=$(${pkgs.yq}/bin/yq -r '.filen_password' /etc/filen-secrets)
        else
          echo "Error: /etc/filen-secrets not found"
          exit 1
        fi

        echo "Starting Filen sync as $FILEN_EMAIL..."
        $FILEN sync /var/lib/filen/syncPairs.json

        echo "Filen sync complete."
      '';
      SuccessExitStatus = "0 1";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # Sync timer - every 15 minutes
  systemd.timers.filen-sync = {
    description = "Regular sync with Filen";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";  # Every 15 minutes
      Persistent = true;
    };
  };

  # ============================================================
  # Manual initialization service (run once to set up)
  # ============================================================
  systemd.services.filen-init = {
    description = "Initialize Filen sync (run once)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.nodejs_22 pkgs.bash pkgs.coreutils pkgs.gnused pkgs.gnugrep ];

    serviceConfig = {
      Type = "oneshot";
      User = primaryUser;
      Group = "users";
      WorkingDirectory = "/var/lib/filen";
      ExecStart = pkgs.writeShellScript "filen-init" ''
        set -euo pipefail

        export PATH="${pkgs.nodejs_22}/bin:$PATH"
        export HOME="/var/lib/filen"
        export FILEN_CLI_DATA_DIR="/var/lib/filen/filen-cli"

        echo "Installing Filen CLI..."
        cd /var/lib/filen
        ${pkgs.nodejs_22}/bin/npm install @filen/cli

        FILEN="/var/lib/filen/node_modules/.bin/filen"

        # Load credentials as environment variables (Filen CLI auth method)
        if [ -f /etc/filen-secrets ]; then
          export FILEN_EMAIL=$(${pkgs.yq}/bin/yq -r '.filen_user' /etc/filen-secrets)
          export FILEN_PASSWORD=$(${pkgs.yq}/bin/yq -r '.filen_password' /etc/filen-secrets)
          echo "Authenticating as $FILEN_EMAIL..."
        else
          echo "Error: /etc/filen-secrets not found"
          exit 1
        fi

        # Create remote directory
        echo "Creating remote /backups directory..."
        $FILEN mkdir /backups 2>/dev/null || true

        # Run initial sync
        echo "Running initial sync..."
        $FILEN sync /var/lib/filen/syncPairs.json

        echo "Filen initialization complete."
      '';
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };
}
