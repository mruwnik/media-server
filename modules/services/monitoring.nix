{ config, lib, pkgs, ... }:

let
  # The test battery (tests/), copied into the store so the hourly health-check
  # runs the SAME checks/*.sh you run by hand. Each check prints failure lines to
  # stdout (empty when healthy) and its report to stderr; notify.sh delivers the
  # collected failures. See tests/README.md.
  healthChecks = pkgs.runCommandLocal "ahiru-health-checks" { } ''
    mkdir -p "$out"
    cp -r ${../../tests}/. "$out"/
    chmod -R u+w "$out"
    chmod +x "$out"/*.sh "$out"/checks/*.sh
  '';
in
{
  # ============================================================
  # Health Monitoring - Email alerts for system issues
  # ============================================================
  # Runs the test battery (tests/checks/*.sh) hourly and emails failures via
  # tests/notify.sh. Configure in /etc/monitoring-config:
  #   notify_email: "your@email.com"
  #   disk_threshold: 90        # (host.sh)      Alert when disk > 90% full
  #   temp_threshold: 70        # (resources.sh) Alert when CPU > 70°C
  #   memory_threshold: 90      # (resources.sh) Alert when RAM > 90% used
  #
  # Coverage lives in tests/ — services, calibre, media, mpd, torrent, backups,
  # resources, host (disk/under-voltage) and the public surface.
  #

  # Check every hour
  systemd.timers.health-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };

  systemd.services.health-check = {
    description = "System health check — runs the test battery, alerts on failures";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Everything checks/*.sh + notify.sh need. /run/wrappers/bin (added in the
    # script) provides setuid sudo for calibre.sh's write-access drop to calibre.
    path = with pkgs; [
      bash coreutils gawk gnugrep gnused systemd curl
      sqlite iproute2 procps libraspberrypi yq jq msmtp
    ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };

    # Run a subset of the battery. Each check writes failure lines to stdout
    # (empty when healthy) and its human report to stderr (-> journal). The
    # collected failures pipe to notify.sh, which no-ops when there is nothing to
    # send. notify_email + thresholds still come from /etc/monitoring-config.
    # No dedup: while a problem persists this re-sends each hour (intentional).
    script = ''
      set -u
      export PATH="/run/wrappers/bin:$PATH"

      HC="${healthChecks}"
      # mpd's :8030 stream is a warning (never alerts); the public checks hairpin
      # through the real domains. Drop a check name here to stop monitoring it.
      CHECKS="systemd calibre media mpd torrent backups resources host public"

      fails="$(mktemp)"
      trap 'rm -f "$fails"' EXIT
      for c in $CHECKS; do
        "$HC/checks/$c.sh" >>"$fails" || true
      done

      "$HC/notify.sh" "[ahiru] health alert" < "$fails"
    '';
  };

  # State + black-box log directories (both on the USB-HDD root)
  systemd.tmpfiles.rules = [
    "d /var/lib/health-check 0755 root root -"
    "d /var/log/blackbox 0755 root root -"
  ];

  # ============================================================
  # Black-box recorder - per-30s flight recorder to disk
  # ============================================================
  # Appends instantaneous resource metrics to /var/log/blackbox/blackbox.log
  # on the USB-HDD root every 30s. These are the signals journald does NOT
  # capture and that tell apart the wedge hypotheses:
  #   - PSI io/cpu/memory stall %  -> I/O livelock vs CPU vs OOM
  #   - D-state process list       -> WHAT is blocked on the disk
  #   - vcgencmd get_throttled     -> undervoltage (bit0 now / bit16 since boot)
  #   - load / temp / mem trend    -> the ramp before death
  # Limitation: if the disk itself hangs, the final append blocks too, so the
  # last ~30s may be lost - but the trend up to the stall, plus the kernel
  # hung-task stack in the journal, is enough to localise the fault.
  #
  # vcgencmd comes from libraspberrypi; if that package name differs in the
  # pinned nixpkgs the throttle line is simply skipped (command -v guard).

  environment.systemPackages = [ pkgs.libraspberrypi ];

  systemd.timers.blackbox-recorder = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "30s";
      AccuracySec = "5s";
    };
  };

  systemd.services.blackbox-recorder = {
    description = "Per-30s resource flight recorder to /var/log/blackbox";
    path = with pkgs; [ coreutils procps gawk gnugrep libraspberrypi ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      # Don't let a hung write pile up instances if the disk stalls.
      TimeoutStartSec = "25s";
    };
    script = ''
      set -u
      LOG=/var/log/blackbox/blackbox.log
      ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
      {
        echo "===== $ts  uptime=$(cut -d' ' -f1 /proc/uptime)s ====="
        echo "load: $(cat /proc/loadavg)"
        for p in cpu io memory; do
          [ -r "/proc/pressure/$p" ] && echo "psi.$p: $(tr '\n' ' ' < /proc/pressure/$p)"
        done
        free -m | awk '/Mem:/{printf "mem: used=%sM free=%sM avail=%sM\n",$3,$4,$7} /Swap:/{printf "swap: used=%sM\n",$3}'
        [ -r /sys/class/thermal/thermal_zone0/temp ] && \
          echo "temp: $(($(cat /sys/class/thermal/thermal_zone0/temp)/1000))C"
        command -v vcgencmd >/dev/null 2>&1 && echo "throttled: $(vcgencmd get_throttled 2>/dev/null)"
        echo "diskstats sda: $(grep -w sda /proc/diskstats || true)"
        echo "D-state (blocked on I/O):"
        ps -eo stat,pid,user,comm,wchan | awk '$1 ~ /^D/ {print "  " $0}'
        echo "top CPU:"
        ps -eo pcpu,pid,user,comm --sort=-pcpu | head -6 | sed 's/^/  /'
        echo
      } >> "$LOG" 2>&1
    '';
  };

  # Keep the recorder log bounded.
  services.logrotate.settings.blackbox = {
    files = "/var/log/blackbox/blackbox.log";
    frequency = "daily";
    rotate = 7;
    compress = true;
    missingok = true;
    notifempty = true;
    copytruncate = true;
  };
}
