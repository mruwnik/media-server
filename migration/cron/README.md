# Cron Jobs Migration

## Custom User Jobs (from OpenMediaVault)

### Anime Downloader (every 6 hours, as `torrents` user)
```
0 */6 * * * torrents
```

Script content:
```bash
#!/bin/sh -l
/media/data/Unsorted/.virtualenvs/anime/bin/python3 /media/data/Unsorted/.download-anime.py >> /media/data/Unsorted/.log/download.log
```

**Migration note**: Need to copy `/media/data/Unsorted/.download-anime.py` and set up Python virtualenv.

### Blog Updater (every 5 minutes, as `dan` user)
```
*/5 * * * * dan
```

Script content:
```bash
#!/bin/sh -l
cd /var/www/ahiru/ && git fetch origin master && git reset --hard FETCH_HEAD && git clean -df && /usr/local/go/bin/hugo
```

**NixOS equivalent**: Use a systemd timer or just deploy statically.

### Backup Updater (every 12 hours, as `dan` user)
```
* */12 * * * dan
```

Script content:
```bash
#!/usr/bin/env bash
for f in `ls ./`; do
    echo "$f"
    if [[ -d $f ]]; then
        cd "$f"
        git fetch origin master
        git reset --hard FETCH_HEAD
        git clean -df
        cd ..
    else
        echo "not dir"
    fi
done
```

**Location**: `/media/data/backups/dan/repos/updater.sh`

### Music Library Rescan (daily)
```bash
#!/bin/sh
/usr/bin/mpc rescan --wait
```

**NixOS equivalent**:
```nix
systemd.timers.mpd-update = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "daily";
    Persistent = true;
  };
};
systemd.services.mpd-update = {
  script = "${pkgs.mpc}/bin/mpc rescan --wait";
  serviceConfig.Type = "oneshot";
};
```

### AI Careers Updater (daily)
```bash
#!/bin/sh
/home/dan/.virtualenvs/ai_careers/bin/python3 /media/data/backups/dan/ai_careers_updater.py > /var/log/ai_careers.log
```

## System Cron Jobs (can be ignored)
- Pi-hole gravity updates (weekly)
- Anacron
- PHP session cleanup
- Apt updates
- OpenMediaVault housekeeping
- Logrotate
- Man-db updates

These will be handled by NixOS modules or aren't needed.

## Files to Copy from Pi

- `/media/data/Unsorted/.download-anime.py`
- `/media/data/backups/dan/ai_careers_updater.py`
- `/media/data/backups/dan/repos/` (the repos being synced)
