{ config, lib, pkgs, ... }:

let
  # Same sandbox as mcp.nix. No MemoryDenyWriteExecute: node's V8 (and the
  # JVM during builds) need writable+executable pages.
  hardening = {
    CapabilityBoundingSet = "";
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    ProtectSystem = "strict";
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged" ];
  };

  # Tools the build needs on PATH. python3/gcc/gnumake are the node-gyp
  # fallback for better-sqlite3 when no prebuilt arm64 binary downloads.
  buildPath = lib.makeBinPath (with pkgs; [
    nodejs clojure git bash coreutils gnugrep python3 gcc gnumake
  ]);

  # Rebuild target/server.js + the UI bundle iff HEAD moved since the last
  # build (or nothing is built yet). shadow-cljs release runs on the JVM;
  # cap the heap so a build can't OOM the Pi. Maven deps land in ~/.m2,
  # npm cache in ~/.npm (HOME=/var/lib/differ). node_modules, target/ and
  # .built-commit are untracked, so `git reset --hard` leaves them alone.
  buildScript = pkgs.writeShellScript "differ-build" ''
    set -euo pipefail
    export PATH=${buildPath}:$PATH
    cd /var/lib/differ/repo

    # Marker includes the node version: a nixpkgs node bump changes the ABI
    # better-sqlite3 was compiled against, so it must trigger a rebuild too.
    stamp="$(git rev-parse HEAD) node-$(node --version)"
    if [ -f target/server.js ] && [ "$(cat .built-commit 2>/dev/null)" = "$stamp" ]; then
      echo "differ already built: $stamp"
      exit 0
    fi

    echo "Building differ: $stamp..."
    npm ci
    clojure -J-Xmx2g -M:build
    echo "$stamp" > .built-commit
  '';
in
{
  # ============================================================
  # Differ - local code review server with MCP integration
  # https://github.com/mruwnik/differ
  # ============================================================
  # Served via nginx as differ.ahiru.pl (see nginx.nix) — :8576 stays
  # firewalled; nginx is the gate because differ's own OAuth accepts
  # everything without verifying.

  users.users.differ = {
    isSystemUser = true;
    group = "differ";
    home = "/var/lib/differ";
    description = "Differ code review server user";
  };
  users.groups.differ = {};

  systemd.tmpfiles.rules = [
    "d /var/lib/differ 0750 differ differ -"
    "d /var/lib/differ/repo 0750 differ differ -"
    "d /var/lib/differ/data 0750 differ differ -"
  ];

  # Clone/update + build on startup. The first build (npm ci + shadow-cljs
  # release on the Pi) takes a long while; oneshot units have no start
  # timeout, but expect the first `nixos-rebuild switch` to block on it.
  systemd.services.differ-setup = {
    description = "Setup differ repository and build";
    wantedBy = [ "multi-user.target" ];
    before = [ "differ.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.git pkgs.openssh ];

    serviceConfig = {
      Type = "oneshot";
      User = "differ";
      Group = "differ";
      WorkingDirectory = "/var/lib/differ";
      RemainAfterExit = true;
    } // hardening // {
      ReadWritePaths = [ "/var/lib/differ" ];
    };

    script = ''
      # Reviewed repos (e.g. ~dan/nixos) belong to other users; without this
      # git refuses to touch them ("dubious ownership").
      printf '[safe]\n\tdirectory = *\n' > /var/lib/differ/.gitconfig

      if [ ! -d /var/lib/differ/repo/.git ]; then
        echo "Cloning differ repository..."
        git clone https://github.com/mruwnik/differ.git /var/lib/differ/repo
      else
        cd /var/lib/differ/repo
        # A dead network at boot shouldn't stop the already-built service.
        git fetch origin && git reset --hard origin/master || echo "fetch failed, keeping current checkout"
      fi

      ${buildScript}
    '';
  };

  # Check for updates every 5 minutes; rebuild + restart only when HEAD moves.
  systemd.timers.differ-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      Persistent = true;
    };
  };

  systemd.services.differ-update = {
    description = "Check for differ updates";
    after = [ "network-online.target" "differ.service" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.git pkgs.util-linux ];

    serviceConfig = {
      Type = "oneshot";
    };

    script = ''
      set -euo pipefail
      REPO_DIR="/var/lib/differ/repo"
      [ -d "$REPO_DIR/.git" ] || exit 0
      cd "$REPO_DIR"
      runuser -u differ -- git fetch origin
      LOCAL=$(runuser -u differ -- git rev-parse HEAD)
      REMOTE=$(runuser -u differ -- git rev-parse origin/master)

      if [ "$LOCAL" != "$REMOTE" ]; then
        echo "Updates found, rebuilding..."
        runuser -u differ -- git reset --hard origin/master
        runuser -u differ -- ${buildScript}
        echo "Restarting differ..."
        systemctl restart differ.service
      else
        echo "No updates"
      fi
    '';
  };

  systemd.services.differ = {
    description = "Differ code review server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "differ-setup.service" ];
    requires = [ "differ-setup.service" ];

    # git for diffs of reviewed repos; node runs the compiled server.
    path = [ pkgs.nodejs pkgs.git ];

    environment = {
      HOME = "/var/lib/differ";
      XDG_DATA_HOME = "/var/lib/differ/data";  # sqlite db: data/differ/review.db
      PORT = "8576";
      DIFFER_URL = "https://differ.ahiru.pl";
    };

    serviceConfig = {
      Type = "simple";
      User = "differ";
      Group = "differ";
      WorkingDirectory = "/var/lib/differ/repo";
      # DIFFER_AUTH_USERNAME/PASSWORD — gates the MCP OAuth flow (differ is
      # internet-reachable via the nginx vhost). Deliberately NOT optional:
      # if deploy-secrets.sh hasn't provisioned it, fail closed rather than
      # silently run with auto-approve token issuance.
      EnvironmentFile = "/etc/differ-secrets";
      ExecStart = "${pkgs.nodejs}/bin/node target/server.js";
      Restart = "always";
      RestartSec = "10";
    } // hardening // {
      # read-only /home so local review sessions can diff repos there
      # (create_pull_request from those repos won't work — reads only).
      ProtectHome = "read-only";
      ReadWritePaths = [ "/var/lib/differ" ];
    };
  };
}
