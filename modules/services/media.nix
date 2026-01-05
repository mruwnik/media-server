{ config, lib, pkgs, ... }:

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
    };
  };

  # Daily music library rescan (like old cron job)
  systemd.services.mpd-rescan = {
    description = "Rescan MPD music library";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.mpc-cli}/bin/mpc update --wait";
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
    mpc-cli  # MPD command-line client
  ];
}
