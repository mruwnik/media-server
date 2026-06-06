{ config, pkgs, ... }:

# Durable, portable song ratings for MPD.
#
# Ratings are written into the file's own tags (FMPS_RATING / POPM) -- the
# source of truth that survives player and database changes -- and mirrored
# into an MPD `rating` sticker (0-10) so myMPD and the MCP server can show and
# set them without filesystem access. An hourly reaper syncs stickers into
# tags and bins (recoverably) every track rated 1 star.
#
# File-touching work runs as the primary user, who owns /media/data/Music; the
# MCP server (user `mcp`) can only set stickers, which the reaper then persists.

let
  user = config.ahiru.primaryUser.name;

  # The rating engine. Talks to MPD over its socket and tags files with
  # mutagen; needs no external binaries.
  mpd-rating = pkgs.writers.writePython3Bin "mpd-rating" {
    libraries = [ pkgs.python3Packages.mutagen ];
    flakeIgnore = [ "E501" "F541" "F841" "W503" "E731" "E203" ];
  } (builtins.readFile ./mpd_rating.py);

  # `mpdrate N [uri]` — rate the current (or given) track.
  mpdrate = pkgs.writeShellScriptBin "mpdrate" ''
    exec ${mpd-rating}/bin/mpd-rating rate "$@"
  '';

  # `mpdbin` — binning *is* one-starring; thin wrapper around the rater.
  mpdbin = pkgs.writeShellScriptBin "mpdbin" ''
    case "''${1:-}" in
      --list)    exec ${mpd-rating}/bin/mpd-rating list ;;
      --restore) shift; exec ${mpd-rating}/bin/mpd-rating restore "$@" ;;
      "")        exec ${mpd-rating}/bin/mpd-rating rate 1 ;;
      *) echo "usage: mpdbin [--list | --restore [query]]   (no args = bin current track)" >&2
         exit 2 ;;
    esac
  '';
in
{
  environment.systemPackages = [ mpd-rating mpdrate mpdbin ];

  # Hourly: persist any stickers (e.g. set via myMPD) into file tags, then bin
  # everything rated 1 star. Runs as the file owner so it can move files.
  systemd.services.mpd-reaper = {
    description = "Sync MPD ratings to file tags and bin 1-star tracks";
    after = [ "mpd.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = user;
    };
    script = "${mpd-rating}/bin/mpd-rating reap";
  };

  systemd.timers.mpd-reaper = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
  };
}
