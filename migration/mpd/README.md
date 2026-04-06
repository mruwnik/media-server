# MPD + Music Streaming Migration

## Data Location

- Music library: `/media/data/Music/`

## Current Setup (from blog mdp.md)

Components:
- **MPD** - Music Player Daemon (apt install mpd)
- **Icecast2** - Streaming server on port 8030 (apt install icecast2)
- **RompR** - Web UI PHP app at `/var/www/media/music/`
- **mpc** - Command line client for testing

### MPD Config

Full config saved in `mpd.conf`. Key settings:

- `music_directory "/media/data/Music"`
- `bind_to_address "localhost"` (local connections only)
- ALSA output to `hw:CARD=Headphones,DEV=0`
- Icecast shout output on port 8030, mount `/mpd`

### Icecast Config (/etc/icecast2/icecast.xml)
- Listening port: 8030
- Hostname: media.ahiru.pl
- Source password: `gwiazdy` (from mpd.conf shout output)

### RompR Setup
Location: `/var/www/media/music/` (already in migration/nginx/www/media/music/)
Requires: `php-curl php-json php-xml php-mbstring php-sqlite3 php-gd php-fpm php-intl imagemagick`
Writable dirs: `prefs/`, `albumart/` (owned by www-data)

### Daily Cron
Music library rescan: `/usr/bin/mpc rescan --wait`

## Known Issues

From CONTEXT.md: "Icecast doesn't work behind nginx reverse proxy"

## NixOS Implementation (PLAN.md approach)

Use MPD's built-in httpd output instead of Icecast:

```nix
services.mpd = {
  enable = true;
  user = "mpd";
  musicDirectory = "/media/data/Music";
  extraConfig = ''
    audio_output {
      type "httpd"
      name "HTTP Stream"
      encoder "lame"
      port "8030"
      bitrate "192"
      format "44100:16:2"
    }
  '';
};
```

## Web UI Options

1. **myMPD** (recommended in PLAN.md) - native NixOS module
2. RompR - PHP app, more complex to set up

```nix
services.mympd = {
  enable = true;
  settings = {
    http_port = 8080;
  };
};
```

## Stream URL

After migration: `http://192.168.0.198:8030/` or proxied via nginx
