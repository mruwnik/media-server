{ config, lib, pkgs, ... }:

let
  primaryUser = config.ahiru.primaryUser.name;
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
      calibreLibrary = "/media/data/Books";
      enableBookUploading = true;
      reverseProxyAuth = {
        enable = true;
        header = "X-Remote-User";
      };
    };
  };

  # Calibre user - system user to access Books directory
  users.users.calibre = {
    isSystemUser = true;
    group = "calibre";
    home = "/media/data/Books";
    description = "Calibre-web service user";
  };
  users.groups.calibre = {};

  # ============================================================
  # MPD - Music Player Daemon
  # ============================================================
  services.mpd = {
    enable = true;
    user = "mpd";
    musicDirectory = "/media/data/Music";
    playlistDirectory = "/var/lib/mpd/playlists";
    dbFile = "/var/lib/mpd/mpd.db";

    extraConfig = ''
      # Only local connections for control
      bind_to_address "localhost"

      # Hardware audio output (3.5mm headphone jack)
      audio_output {
        type        "alsa"
        name        "Headphones"
        device      "hw:CARD=Headphones,DEV=0"
        mixer_type  "software"
      }

      # HTTP streaming output (replaces Icecast)
      audio_output {
        type        "httpd"
        name        "HTTP Stream"
        encoder     "lame"
        port        "8030"
        bitrate     "192"
        format      "44100:16:2"
        always_on   "yes"
        tags        "yes"
      }

      # Null output for when no listeners (prevents MPD from pausing)
      audio_output {
        type   "null"
        name   "Null Output"
      }
    '';
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

      # Create users with appropriate roles
      # role=1 is admin, role=0 is reader (can browse/download)
      create_user() {
        local user=$1
        local role=$2
        EXISTS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM user WHERE name='$user';")
        if [ "$EXISTS" -eq 0 ]; then
          echo "Creating calibre-web user: $user (role=$role)"
          sqlite3 "$DB" "INSERT INTO user (name, email, password, role, sidebar_view, default_language, locale, view_settings) VALUES ('$user', '$user@local', '''''', $role, 4095, 'en', 'en', '${"{}"}');"
        else
          echo "User $user already exists"
        fi
      }

      create_user "${primaryUser}" 1      # admin
      create_user "nadia" 0    # reader
      create_user "rumun" 0    # reader
    '';
  };
}
