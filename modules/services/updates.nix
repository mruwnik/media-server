{ config, lib, pkgs, ... }:

let
  primaryUser = config.ahiru.primaryUser.name;
in
{
  # ============================================================
  # Auto-Update Service - Pulls config changes and rebuilds
  # ============================================================
  # Configure recipient in /etc/update-notify-config:
  #   notify_email: "your@email.com"

  # Daily timer to check for updates
  systemd.timers.nixos-update-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";  # Spread load
    };
  };

  systemd.services.nixos-update-check = {
    description = "Auto-update NixOS from git and notify via email";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = with pkgs; [ git nix coreutils gnugrep diffutils msmtp nixos-rebuild ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };

    script = ''
      set -euo pipefail

      CONFIG="/etc/update-notify-config"
      NIXOS_DIR="/home/${primaryUser}/nixos"
      LOG_FILE="/tmp/nixos-rebuild-$$.log"

      # Allow root to access user-owned git repo
      git config --global --add safe.directory "$NIXOS_DIR" 2>/dev/null || true

      # Load config
      if [ ! -f "$CONFIG" ]; then
        echo "Config not found: $CONFIG - skipping update check"
        exit 0
      fi

      NOTIFY_EMAIL=$(${pkgs.yq}/bin/yq -r '.notify_email // empty' "$CONFIG")
      if [ -z "$NOTIFY_EMAIL" ]; then
        echo "No notify_email configured - skipping"
        exit 0
      fi

      # Check if nixos repo exists
      if [ ! -d "$NIXOS_DIR/.git" ]; then
        echo "NixOS config not found at $NIXOS_DIR"
        exit 0
      fi

      cd "$NIXOS_DIR"

      # Fetch latest from remote
      export GIT_SSH_COMMAND="ssh -i /home/${primaryUser}/.ssh/id_ed25519 -o UserKnownHostsFile=/root/.ssh/known_hosts -o StrictHostKeyChecking=accept-new"
      git fetch origin 2>/dev/null || true

      # Get current and remote commits
      LOCAL=$(git rev-parse HEAD)

      # Detect remote branch
      if git show-ref --verify --quiet refs/remotes/origin/main; then
        REMOTE_BRANCH="origin/main"
      else
        REMOTE_BRANCH="origin/master"
      fi
      REMOTE=$(git rev-parse "$REMOTE_BRANCH")

      # Check for config repo updates
      CONFIG_UPDATED=""
      COMMIT_LOG=""
      if [ "$LOCAL" != "$REMOTE" ]; then
        COMMITS_BEHIND=$(git rev-list --count HEAD.."$REMOTE_BRANCH")
        COMMIT_LOG=$(git log --oneline HEAD.."$REMOTE_BRANCH" | head -10)

        echo "Found $COMMITS_BEHIND new commit(s) - pulling and rebuilding..."

        # Pull changes
        git pull --ff-only origin "$(echo $REMOTE_BRANCH | sed 's|origin/||')" 2>&1 | tee -a "$LOG_FILE"

        # Rebuild
        REBUILD_STATUS="success"
        if nixos-rebuild switch --flake .#ahiru 2>&1 | tee -a "$LOG_FILE"; then
          echo "Rebuild successful"
          CONFIG_UPDATED="success"
        else
          REBUILD_STATUS="failed"
          CONFIG_UPDATED="failed"
          echo "Rebuild failed"
        fi
      fi

      # Check for flake input updates (nixpkgs, etc.)
      FLAKE_UPDATES=""
      FLAKE_STATE_FILE="/var/lib/nixos-update-check/flake-state"
      mkdir -p /var/lib/nixos-update-check

      if [ -f "$NIXOS_DIR/flake.lock" ]; then
        cp "$NIXOS_DIR/flake.lock" /tmp/flake.lock.before

        echo "Checking flake inputs for updates..."
        if nix flake update --refresh --flake "$NIXOS_DIR" 2>&1; then
          if ! diff -q /tmp/flake.lock.before "$NIXOS_DIR/flake.lock" >/dev/null 2>&1; then
            FLAKE_UPDATES=$(diff -u /tmp/flake.lock.before "$NIXOS_DIR/flake.lock" | grep -E "^[+-].*\"(rev|lastModified)\"" | head -40 || true)
            echo "Flake updates detected:"
            echo "$FLAKE_UPDATES"
          else
            echo "No flake input updates."
          fi
          # Restore original - don't auto-apply flake updates
          cp /tmp/flake.lock.before "$NIXOS_DIR/flake.lock"
        else
          echo "nix flake update failed (ignoring)."
        fi
        rm -f /tmp/flake.lock.before
      fi

      # Check if we already notified about these flake updates
      FLAKE_HASH=$(echo "$FLAKE_UPDATES" | md5sum | cut -d' ' -f1)
      LAST_FLAKE_HASH=""
      if [ -f "$FLAKE_STATE_FILE" ]; then
        LAST_FLAKE_HASH=$(cat "$FLAKE_STATE_FILE")
      fi

      NOTIFY_FLAKE=""
      if [ -n "$FLAKE_UPDATES" ] && [ "$FLAKE_HASH" != "$LAST_FLAKE_HASH" ]; then
        NOTIFY_FLAKE="yes"
        echo "$FLAKE_HASH" > "$FLAKE_STATE_FILE"
      fi

      # Send emails as needed
      if [ -n "$CONFIG_UPDATED" ]; then
        {
          if [ "$CONFIG_UPDATED" = "success" ]; then
            echo "Subject: [ahiru] NixOS config updated successfully"
          else
            echo "Subject: [ahiru] NixOS config update FAILED"
          fi
          echo "To: $NOTIFY_EMAIL"
          echo "Content-Type: text/plain; charset=utf-8"
          echo ""

          if [ "$CONFIG_UPDATED" = "success" ]; then
            echo "NixOS config on ahiru.pl has been updated successfully."
          else
            echo "NixOS config update on ahiru.pl FAILED. Manual intervention required."
          fi
          echo ""
          echo "=== Applied Commits ==="
          echo "$COMMIT_LOG"
          echo ""
          echo "=== Rebuild Output (last 50 lines) ==="
          tail -50 "$LOG_FILE"
          echo ""
          echo "---"
          echo "Sent from ahiru.pl auto-updater"
        } | msmtp -t
      fi

      if [ -n "$NOTIFY_FLAKE" ]; then
        {
          echo "Subject: [ahiru] NixOS upstream updates available"
          echo "To: $NOTIFY_EMAIL"
          echo "Content-Type: text/plain; charset=utf-8"
          echo ""
          echo "Upstream NixOS/nixpkgs updates are available for ahiru.pl"
          echo ""
          echo "=== Flake Input Changes ==="
          echo "$FLAKE_UPDATES"
          echo ""
          echo "=== To Apply ==="
          echo "ssh ${primaryUser}@ahiru.pl"
          echo "cd ~/nixos"
          echo "nix flake update"
          echo "sudo nixos-rebuild switch --flake .#ahiru"
          echo ""
          echo "---"
          echo "Sent from ahiru.pl update checker"
        } | msmtp -t
      fi

      rm -f "$LOG_FILE"

      if [ "$CONFIG_UPDATED" = "failed" ]; then
        exit 1
      fi
    '';
  };
}
