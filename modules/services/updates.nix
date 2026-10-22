{ config, lib, pkgs, ... }:

let
  primaryUser = config.ahiru.primaryUser.name;

  # Closure-aware analyzer: given the old and new flake.lock and a working
  # directory holding the updated flake, emits an email body to stdout.
  # First line is the subject (without the [ahiru] prefix).
  analyzeFlakeUpdate = pkgs.writers.writePython3Bin "analyze-flake-update" {
    flakeIgnore = [ "E501" "F541" "F841" "W503" "E731" ];
  } (builtins.readFile ./analyze_flake_update.py);
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

    path = with pkgs; [
      git
      nix
      coreutils
      gnugrep
      diffutils
      msmtp
      nixos-rebuild
      gnutar
      analyzeFlakeUpdate
    ];

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
        if nixos-rebuild switch --flake .#ahiru 2>&1 | tee -a "$LOG_FILE"; then
          echo "Rebuild successful"
          CONFIG_UPDATED="success"
        else
          CONFIG_UPDATED="failed"
          echo "Rebuild failed"
        fi
      fi

      # Send config-update email if applicable
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

      # ============================================================
      # Daily flake-update heartbeat with closure-aware analysis
      # ============================================================
      # Always sends one email per run. Subject classifies impact so
      # quiet days can be filtered by a mail rule if desired.

      WORK=$(mktemp -d)
      trap 'rm -rf "$WORK" "$LOG_FILE" /tmp/flake.lock.before' EXIT

      # Materialize the flake into a working dir so we never mutate
      # the live one. git archive captures tracked state; we then
      # overlay the live flake.lock (which may be ahead of HEAD).
      git archive HEAD | tar -x -C "$WORK"
      cp flake.lock "$WORK/flake.lock"
      cp "$WORK/flake.lock" /tmp/flake.lock.before

      echo "Refreshing flake inputs in $WORK..."
      if (cd "$WORK" && nix flake update --refresh) 2>&1 | tee -a "$LOG_FILE"; then
        BODY=$(analyze-flake-update /tmp/flake.lock.before "$WORK/flake.lock" "$WORK" 2>&1 || echo "Analyzer failed; see service journal.")
        SUBJECT=$(printf '%s\n' "$BODY" | head -n1)
        REST=$(printf '%s\n' "$BODY" | tail -n +2)
        {
          echo "Subject: [ahiru] $SUBJECT"
          echo "To: $NOTIFY_EMAIL"
          echo "Content-Type: text/plain; charset=utf-8"
          echo ""
          echo "$REST"
          echo ""
          echo "---"
          echo "Sent from ahiru.pl update checker (heartbeat: always sends)"
        } | msmtp -t
      else
        {
          echo "Subject: [ahiru] Update checker: flake refresh FAILED"
          echo "To: $NOTIFY_EMAIL"
          echo "Content-Type: text/plain; charset=utf-8"
          echo ""
          echo "nix flake update --refresh failed. Last 50 log lines:"
          echo ""
          tail -50 "$LOG_FILE"
          echo ""
          echo "---"
          echo "Sent from ahiru.pl update checker"
        } | msmtp -t
      fi

      rm -f /tmp/flake.lock.before

      if [ "$CONFIG_UPDATED" = "failed" ]; then
        exit 1
      fi
    '';
  };
}
