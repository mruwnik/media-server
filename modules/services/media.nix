{ config, pkgs, ... }:

let
  primaryUser = config.ahiru.primaryUser.name;
  bookLibrary = "/media/data/Books";
in
{
  # Open port for MPD HTTP stream (direct access from LAN)
  networking.firewall.allowedTCPPorts = [ 8030 ];

  # ============================================================
  # Calibre-web - Ebook library web interface
  # ============================================================
  services.calibre-web = {
    enable = true;
    user = "calibre";
    group = "calibre";
    listen = {
      ip = "127.0.0.1";
      port = 8083;
    };
    options = {
      calibreLibrary = bookLibrary;
      enableBookUploading = true;
      reverseProxyAuth = {
        enable = true;
        header = "X-Remote-User";
      };
    };
  };

  # Sandbox the (publicly proxied) calibre-web service. The nixpkgs module sets
  # none of this. StateDirectory=calibre-web keeps app.db writable under
  # ProtectSystem=strict; the library needs an explicit grant. No
  # MemoryDenyWriteExecute — Python/cffi needs W+X pages.
  systemd.services.calibre-web = {
    unitConfig.RequiresMountsFor = bookLibrary;
    serviceConfig = {
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
      ReadWritePaths = [ bookLibrary ];
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" ];
    };
  };

  # Calibre user - system user to access Books directory.
  # Member of `users` (the library's owning group) so calibre-web can WRITE the
  # library: edit metadata, regenerate covers, and accept uploads. Group write
  # comes from a g:users:rwx ACL whose mask is kept rwx by the 0775 tmpfiles
  # rule in storage.nix.
  users.users.calibre = {
    isSystemUser = true;
    group = "calibre";
    extraGroups = [ "users" ];
    home = bookLibrary;
    description = "Calibre-web service user";
  };
  users.groups.calibre = {};

  # ============================================================
  # MPD - Music Player Daemon
  # ============================================================
  services.mpd = {
    enable = true;
    user = "mpd";

    settings = {
      music_directory = "/media/data/Music";
      playlist_directory = "/var/lib/mpd/playlists";
      # Explicit: the 26.05 default is ${dataDir}/tag_cache, which would orphan
      # the existing db and force a full rescan of the library.
      db_file = "/var/lib/mpd/mpd.db";

      # Only local connections for control
      bind_to_address = "localhost";

      audio_output = [
        # Hardware audio output (3.5mm headphone jack)
        {
          type = "alsa";
          name = "Headphones";
          device = "hw:CARD=Headphones,DEV=0";
          mixer_type = "software";
        }
        # HTTP streaming output (replaces Icecast)
        {
          type = "httpd";
          name = "HTTP Stream";
          encoder = "lame";
          port = 8030;
          bitrate = 192;
          format = "44100:16:2";
          always_on = "yes";
          tags = "yes";
        }
        # Null output for when no listeners (prevents MPD from pausing)
        {
          type = "null";
          name = "Null Output";
        }
      ];
    };
  };

  # MPD user needs access to Music directory
  users.users.mpd.extraGroups = [ "audio" ];

  # ============================================================
  # myMPD - Modern web UI for MPD
  # ============================================================
  services.mympd = {
    enable = true;
    settings = {
      http_port = 8080;
      http_host = "127.0.0.1";
      mympd_uri = "/music";
    };
  };

  # Daily music library rescan (like old cron job)
  systemd.services.mpd-rescan = {
    description = "Rescan MPD music library";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.mpc}/bin/mpc update --wait";
      User = "mpd";
    };
  };

  systemd.timers.mpd-rescan = {
    description = "Daily MPD library rescan";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };

  environment.systemPackages = with pkgs; [
    mpc     # MPD command-line client
    alsa-utils  # aplay, amixer, etc.
    sqlite      # For calibre-web user sync
  ];

  # Sync htpasswd users to calibre-web before it starts
  systemd.services.calibre-web-user-sync = {
    description = "Sync htpasswd users to Calibre-Web";
    before = [ "calibre-web.service" ];
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];

    path = [ pkgs.sqlite ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      DB="/var/lib/calibre-web/app.db"

      # Wait for database to exist (created by calibre-web on first run)
      if [ ! -f "$DB" ]; then
        echo "Calibre-web database not found yet, skipping user sync"
        exit 0
      fi

      # Create users with appropriate roles. `role` is a calibre-web permission
      # bitmask: ADMIN=1, DOWNLOAD=2, UPLOAD=4, EDIT=8, PASSWD=16, ANON=32,
      # EDIT_SHELVES=64, DELETE=128, VIEWER=256. 479 = the full admin set (all
      # but ANON) — needed to UPLOAD/download/edit from the web UI; admin(1)
      # alone only unlocks the settings panel. role=0 = browse only (no download).
      create_user() {
        local user=$1
        local role=$2
        EXISTS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM user WHERE name='$user';")
        if [ "$EXISTS" -eq 0 ]; then
          echo "Creating calibre-web user: $user (role=$role)"
          # NB: default_language is calibre-web's *book-content* language filter
          # (User.filter_language() returns it), NOT the UI language. It must be
          # 'all' or the user sees only books whose language matches exactly.
          # The library uses ISO 639-2 codes ('eng', 'pol', ...), so 'en' matched
          # zero books and the library appeared empty. locale ('en') is the UI lang.
          sqlite3 "$DB" "INSERT INTO user (name, email, password, role, sidebar_view, default_language, locale, view_settings) VALUES ('$user', '$user@local', '''''', $role, 4095, 'all', 'en', '${"{}"}');"
        else
          echo "User $user already exists"
        fi
      }

      create_user "${primaryUser}" 479    # full admin (incl. upload/download/edit)
      create_user "nadia" 0    # reader
      create_user "rumun" 0    # reader
    '';
  };
}
