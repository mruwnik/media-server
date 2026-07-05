{ config, lib, pkgs, ... }:

let
  # Systemd sandbox for the mcp units. No MemoryDenyWriteExecute: the venv
  # pulls in cffi-based wheels (bcrypt, cryptography) whose libffi closures
  # need writable+executable pages. AF_NETLINK stays allowed — getifaddrs()
  # uses it and returns EPERM (not an ignorable error) when filtered.
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
in
{
  # ============================================================
  # Local MCP Server - Music/MPD control and anime management
  # https://github.com/mruwnik/raspberry-mcp
  # ============================================================

  # System packages needed
  environment.systemPackages = with pkgs; [
    git
    python312
    uv
  ];

  # MCP service user
  users.users.mcp = {
    isSystemUser = true;
    group = "mcp";
    home = "/var/lib/mcp";
    description = "Local MCP server user";
    extraGroups = [ "htpasswd-readers" "users" ];  # htpasswd + write to torrent watch dir
  };
  users.groups.mcp = {};

  # Ensure directories exist
  systemd.tmpfiles.rules = [
    "d /var/lib/mcp 0750 mcp mcp -"
    "d /var/lib/mcp/repo 0750 mcp mcp -"
  ];

  # Grant mcp user write access to Unsorted for anime downloads
  system.activationScripts.mcpAnimeAccess = lib.stringAfter [ "users" ] ''
    ${pkgs.acl}/bin/setfacl -m u:mcp:rwx /media/data/Unsorted 2>/dev/null || true
    ${pkgs.acl}/bin/setfacl -d -m u:mcp:rwx /media/data/Unsorted 2>/dev/null || true
  '';

  # Clone/update repo on startup
  systemd.services.mcp-setup = {
    description = "Setup Local MCP repository";
    wantedBy = [ "multi-user.target" ];
    before = [ "mcp.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.git pkgs.openssh ];

    serviceConfig = {
      Type = "oneshot";
      User = "mcp";
      Group = "mcp";
      WorkingDirectory = "/var/lib/mcp";
      RemainAfterExit = true;
    } // hardening // {
      ReadWritePaths = [ "/var/lib/mcp" ];
    };

    script = ''
      if [ ! -d /var/lib/mcp/repo/.git ]; then
        echo "Cloning raspberry-mcp repository..."
        git clone https://github.com/mruwnik/raspberry-mcp.git /var/lib/mcp/repo
      else
        echo "Updating raspberry-mcp repository..."
        cd /var/lib/mcp/repo
        git fetch origin
        git reset --hard origin/master
      fi
    '';
  };

  # Timer to check for MCP updates every 5 minutes
  systemd.timers.mcp-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";  # Every 5 minutes
      Persistent = true;
    };
  };

  systemd.services.mcp-update = {
    description = "Check for MCP server updates";
    after = [ "network-online.target" "mcp.service" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.git pkgs.util-linux ];

    serviceConfig = {
      Type = "oneshot";
    };

    script = ''
      set -euo pipefail
      REPO_DIR="/var/lib/mcp/repo"
      if [ -d "$REPO_DIR/.git" ]; then
        cd "$REPO_DIR"
        # Run git commands as mcp user (owns the repo)
        runuser -u mcp -- git fetch origin
        LOCAL=$(runuser -u mcp -- git rev-parse HEAD)
        REMOTE=$(runuser -u mcp -- git rev-parse origin/master)

        if [ "$LOCAL" != "$REMOTE" ]; then
          echo "Updates found, updating..."
          runuser -u mcp -- git reset --hard origin/master
          echo "Restarting MCP service..."
          systemctl restart mcp.service
        else
          echo "No updates"
        fi
      fi
    '';
  };

  # Timer to check for new anime every 4 hours
  systemd.timers.anime-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 0/4:00:00";  # Every 4 hours
      Persistent = true;
    };
  };

  systemd.services.anime-check = {
    description = "Check for new anime episodes";
    after = [ "network-online.target" "mcp-setup.service" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.python312 pkgs.uv pkgs.git ];

    environment = {
      HOME = "/var/lib/mcp";
      ANIME_BASE_PATH = "/media/data/Unsorted";
    };

    unitConfig.RequiresMountsFor = "/media/data";
    serviceConfig = {
      Type = "oneshot";
      User = "mcp";
      Group = "mcp";
      WorkingDirectory = "/var/lib/mcp/repo";
      ExecStart = "${pkgs.uv}/bin/uv run anime-check";
    } // hardening // {
      ReadWritePaths = [ "/var/lib/mcp" "/media/data/Unsorted" ];
    };
  };

  # Main MCP service
  systemd.services.mcp = {
    description = "Local MCP Server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "mcp-setup.service" "mpd.service" ];
    requires = [ "mcp-setup.service" ];
    unitConfig.RequiresMountsFor = "/media/data";

    path = [ pkgs.python312 pkgs.uv pkgs.git ];

    environment = {
      HOME = "/var/lib/mcp";
      LOCAL_MCP_PORT = "3001";
      LOCAL_MCP_BASE_URL = "https://ahiru.pl";
      LOCAL_MCP_HTPASSWD = "/etc/shared-htpasswd";
      MPD_HOST = "localhost";
      MPD_PORT = "6600";
      ANIME_BASE_PATH = "/media/data/Unsorted";
    };

    serviceConfig = {
      Type = "simple";
      User = "mcp";
      Group = "mcp";
      WorkingDirectory = "/var/lib/mcp/repo";
      ExecStart = "${pkgs.uv}/bin/uv run local-mcp";
      Restart = "always";
      RestartSec = "10";
    } // hardening // {
      # /var/lib/mcp: repo checkout + uv venv/cache (HOME). Unsorted: anime
      # downloads + rtorrent .watch drops. htpasswd + MPD are read/socket only.
      ReadWritePaths = [ "/var/lib/mcp" "/media/data/Unsorted" ];
    };
  };
}
