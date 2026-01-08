{ config, lib, pkgs, ... }:

let
  primaryUser = config.ahiru.primaryUser.name;
in
{
  # ============================================================
  # Update Notifications - Email when NixOS updates are available
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
    description = "Check for NixOS updates and notify via email";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = with pkgs; [ git nix coreutils gnugrep msmtp ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };

    script = ''
      set -euo pipefail

      CONFIG="/etc/update-notify-config"
      NIXOS_DIR="/home/${primaryUser}/nixos"
      STATE_FILE="/var/lib/nixos-update-check/last-check"

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

      # Ensure state directory exists
      mkdir -p /var/lib/nixos-update-check

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

      # Check flake inputs for updates
      FLAKE_UPDATES=""
      if command -v nix &>/dev/null; then
        # Check if any flake inputs have updates
        FLAKE_UPDATES=$(nix flake update --dry-run 2>&1 | grep -E "updated|→" || true)
      fi

      # Determine if we should notify
      SHOULD_NOTIFY=""
      NOTIFY_REASON=""

      if [ "$LOCAL" != "$REMOTE" ]; then
        COMMITS_BEHIND=$(git rev-list --count HEAD.."$REMOTE_BRANCH")
        SHOULD_NOTIFY="yes"
        NOTIFY_REASON="Config repo has $COMMITS_BEHIND new commit(s)"

        # Get commit summaries
        COMMIT_LOG=$(git log --oneline HEAD.."$REMOTE_BRANCH" | head -10)
      fi

      if [ -n "$FLAKE_UPDATES" ]; then
        SHOULD_NOTIFY="yes"
        NOTIFY_REASON="''${NOTIFY_REASON:+$NOTIFY_REASON\n\n}Flake inputs have updates available"
      fi

      # Check against last notification to avoid spam
      LAST_NOTIFIED=""
      if [ -f "$STATE_FILE" ]; then
        LAST_NOTIFIED=$(cat "$STATE_FILE")
      fi

      CURRENT_STATE="$LOCAL:$REMOTE:$(echo "$FLAKE_UPDATES" | md5sum | cut -d' ' -f1)"

      if [ "$CURRENT_STATE" = "$LAST_NOTIFIED" ]; then
        echo "Already notified about current state - skipping"
        exit 0
      fi

      if [ -n "$SHOULD_NOTIFY" ]; then
        echo "Updates available - sending notification to $NOTIFY_EMAIL"

        # Build email
        {
          echo "Subject: [ahiru] NixOS updates available"
          echo "To: $NOTIFY_EMAIL"
          echo "Content-Type: text/plain; charset=utf-8"
          echo ""
          echo "NixOS updates are available on ahiru.pl"
          echo ""
          echo "=== Summary ==="
          echo -e "$NOTIFY_REASON"
          echo ""

          if [ -n "''${COMMIT_LOG:-}" ]; then
            echo "=== New Commits ==="
            echo "$COMMIT_LOG"
            echo ""
          fi

          if [ -n "$FLAKE_UPDATES" ]; then
            echo "=== Flake Input Updates ==="
            echo "$FLAKE_UPDATES"
            echo ""
          fi

          echo "=== To Update ==="
          echo "ssh ${primaryUser}@ahiru.pl"
          echo "cd ~/nixos && git pull"
          echo "sudo nixos-rebuild switch --flake .#ahiru"
          echo ""
          echo "---"
          echo "Sent from ahiru.pl update checker"
        } | msmtp -t

        # Save state to prevent duplicate notifications
        echo "$CURRENT_STATE" > "$STATE_FILE"
        echo "Notification sent"
      else
        echo "No updates available"
      fi
    '';
  };

  # State directory for tracking notifications
  systemd.tmpfiles.rules = [
    "d /var/lib/nixos-update-check 0755 root root -"
  ];
}
