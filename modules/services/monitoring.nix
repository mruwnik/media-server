{ config, lib, pkgs, ... }:

{
  # ============================================================
  # Health Monitoring - Email alerts for system issues
  # ============================================================
  # Configure in /etc/monitoring-config:
  #   notify_email: "your@email.com"
  #   disk_threshold: 90        # Alert when disk > 90% full
  #   temp_threshold: 70        # Alert when CPU > 70°C
  #   memory_threshold: 90      # Alert when RAM > 90% used
  #
  # Services monitored: nginx, rtorrent, flood, calibre-web, mympd, radicale
  # HTTP endpoints tested: ahiru.pl, media.ahiru.pl/*
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
    description = "System health check with email alerts";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = with pkgs; [ coreutils gawk gnugrep systemd msmtp curl bash ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };

    script = ''
      set -euo pipefail

      CONFIG="/etc/monitoring-config"
      STATE_DIR="/var/lib/health-check"
      STATE_FILE="$STATE_DIR/alert-state"

      mkdir -p "$STATE_DIR"

      # Load config
      if [ ! -f "$CONFIG" ]; then
        echo "Config not found: $CONFIG - skipping health check"
        exit 0
      fi

      NOTIFY_EMAIL=$(${pkgs.yq}/bin/yq -r '.notify_email // empty' "$CONFIG")
      DISK_THRESHOLD=$(${pkgs.yq}/bin/yq -r '.disk_threshold // 90' "$CONFIG")
      TEMP_THRESHOLD=$(${pkgs.yq}/bin/yq -r '.temp_threshold // 70' "$CONFIG")
      MEMORY_THRESHOLD=$(${pkgs.yq}/bin/yq -r '.memory_threshold // 90' "$CONFIG")

      if [ -z "$NOTIFY_EMAIL" ]; then
        echo "No notify_email configured - skipping"
        exit 0
      fi

      ALERTS=""
      WARNINGS=""

      # ---- Disk Space ----
      while read -r line; do
        usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
        mount=$(echo "$line" | awk '{print $6}')
        if [ "$usage" -ge "$DISK_THRESHOLD" ]; then
          ALERTS="$ALERTS\n⚠️  Disk $mount is $usage% full"
        fi
      done < <(df -h | grep -E '^/dev/' | grep -v '/boot')

      # ---- CPU Temperature ----
      if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp)
        temp=$((temp_raw / 1000))
        if [ "$temp" -ge "$TEMP_THRESHOLD" ]; then
          ALERTS="$ALERTS\n🌡️  CPU temperature is $temp°C (threshold: $TEMP_THRESHOLD°C)"
        fi
      fi

      # ---- Memory Usage ----
      mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
      mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
      mem_used=$((mem_total - mem_avail))
      mem_percent=$((mem_used * 100 / mem_total))
      if [ "$mem_percent" -ge "$MEMORY_THRESHOLD" ]; then
        ALERTS="$ALERTS\n💾 Memory usage is $mem_percent% (threshold: $MEMORY_THRESHOLD%)"
      fi

      # ---- Service Health ----
      SERVICES="nginx rtorrent flood calibre-web mympd radicale"
      for svc in $SERVICES; do
        if systemctl is-enabled "$svc" &>/dev/null; then
          if ! systemctl is-active --quiet "$svc"; then
            ALERTS="$ALERTS\n🔴 Service $svc is not running"
          fi
        fi
      done

      # ---- Load Average ----
      load=$(cat /proc/loadavg | awk '{print $1}')
      cores=$(nproc)
      # Alert if load > 2x cores for sustained period
      load_int=$(echo "$load" | cut -d. -f1)
      if [ "$load_int" -ge $((cores * 2)) ]; then
        WARNINGS="$WARNINGS\n📈 High load average: $load (cores: $cores)"
      fi

      # ---- HTTP Endpoint Tests ----
      if [ -f /root/test-services.sh ]; then
        echo "Running HTTP endpoint tests..."
        TEST_OUTPUT=$(/root/test-services.sh 2>&1) || true
        TEST_EXIT=$?

        if [ $TEST_EXIT -ne 0 ]; then
          # Extract failed tests from output
          FAILED_TESTS=$(echo "$TEST_OUTPUT" | grep -E "FAIL" | head -10 || true)
          if [ -n "$FAILED_TESTS" ]; then
            ALERTS="$ALERTS\n🌐 HTTP endpoint tests failed:\n$FAILED_TESTS"
          else
            ALERTS="$ALERTS\n🌐 HTTP endpoint tests failed (exit code $TEST_EXIT)"
          fi
        else
          echo "HTTP endpoint tests passed"
        fi
      fi

      # ---- Check if we should send alert ----
      CURRENT_ALERTS=$(echo -e "$ALERTS$WARNINGS" | sort | md5sum | cut -d' ' -f1)
      LAST_ALERTS=""
      if [ -f "$STATE_FILE" ]; then
        LAST_ALERTS=$(cat "$STATE_FILE")
      fi

      if [ -n "$ALERTS" ] || [ -n "$WARNINGS" ]; then
        # Only send if alerts changed (avoid hourly spam for same issue)
        if [ "$CURRENT_ALERTS" != "$LAST_ALERTS" ]; then
          echo "Health issues detected - sending alert to $NOTIFY_EMAIL"

          {
            echo "Subject: [ahiru] ⚠️ Health alert"
            echo "To: $NOTIFY_EMAIL"
            echo "Content-Type: text/plain; charset=utf-8"
            echo ""
            echo "Health issues detected on ahiru.pl"
            echo ""
            echo "=== Alerts ==="
            if [ -n "$ALERTS" ]; then
              echo -e "$ALERTS"
            else
              echo "(none)"
            fi
            echo ""
            if [ -n "$WARNINGS" ]; then
              echo "=== Warnings ==="
              echo -e "$WARNINGS"
              echo ""
            fi
            echo "=== System Info ==="
            echo "Uptime: $(uptime -p)"
            echo "Load: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
            echo ""
            echo "---"
            echo "Sent from ahiru.pl health monitor"
          } | msmtp -t

          echo "$CURRENT_ALERTS" > "$STATE_FILE"
          echo "Alert sent"
        else
          echo "Same alerts as before - not re-sending"
        fi
      else
        echo "All systems healthy"
        # Clear state when healthy (so next issue triggers alert)
        rm -f "$STATE_FILE"
      fi
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
