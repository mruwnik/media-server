{ config, lib, pkgs, ... }:

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
  # library: edit metadata, regenerate covers, and accept uploads. The library
  # dirs are setgid + group=users, so new entries stay group-owned by users.
  # NB: /media/data/Books uses POSIX ACLs with a restrictive mask, so plain
  # `chmod g+w` is NOT enough — the mask caps effective group perms at r-x.
  # Group write is (re)granted declaratively by the activation script + the
  # post-mount service below.
  users.users.calibre = {
    isSystemUser = true;
    group = "calibre";
    extraGroups = [ "users" ];
    home = bookLibrary;
    description = "Calibre-web service user";
  };
  users.groups.calibre = {};

  # Because the library is calibre's home, the `users` activation step chmods
  # it and resets the ACL mask to r-x, which re-caps the g:users:rwx grant and
  # leaves calibre unable to write the library (edit metadata, covers, uploads).
  # Re-apply the group-write ACL after that step on every rebuild — same pattern
  # mcp.nix uses for /media/data/Unsorted. Only the top dir needs it (subdirs are
  # setgid + already carry the ACL, and inherit the default for new entries).
  system.activationScripts.calibreLibraryAccess = lib.stringAfter [ "users" ] ''
    ${pkgs.acl}/bin/setfacl -m g:users:rwx ${bookLibrary} 2>/dev/null || true
    ${pkgs.acl}/bin/setfacl -d -m g:users:rwx ${bookLibrary} 2>/dev/null || true
  '';

  # The activation script alone is not enough: on a `switch` that restarts
  # calibre-web, the mask gets re-stomped to r-x *after* the activation script
  # ran, and on a fresh boot the script fires before the USB HDD (/media/data =
  # sda2) is mounted, so its setfacl hits the bare mountpoint and no-ops. Re-grant
  # the ACL from a unit tied to calibre-web's own lifecycle instead: ordered
  # `before` it, pulled in by it (wantedBy), non-persistent (RemainAfterExit =
  # false) so it re-runs before *every* calibre-web (re)start — boot and
  # switch-restart alike — and RequiresMountsFor so on boot it waits for the HDD
  # and setfacl hits the real on-disk dir. This is the authoritative grant; the
  # activation script above only covers a `switch` that leaves calibre-web
  # running (mask stomped mid-run, no restart to trigger this unit).
  systemd.services.calibre-library-acl = {
    description = "Re-grant calibre group-write on the book library (before calibre-web)";
    wantedBy = [ "calibre-web.service" ];
    before = [ "calibre-web.service" ];
    unitConfig.RequiresMountsFor = bookLibrary;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
    script = ''
      ${pkgs.acl}/bin/setfacl -m g:users:rwx ${bookLibrary}
      ${pkgs.acl}/bin/setfacl -d -m g:users:rwx ${bookLibrary}
    '';
  };

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
