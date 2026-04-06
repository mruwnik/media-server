# rtorrent Migration

## Files

- `rtorrent.rc` - rtorrent configuration
- `rtorrent.service` - systemd service file

## Paths

| Purpose | Path |
|---------|------|
| Base directory | /media/data/Unsorted/ |
| Downloading | /media/data/Unsorted/.downloading/ |
| Session | /media/data/Unsorted/.session/ |
| Watch (load) | /media/data/Unsorted/.watch/load/ |
| Watch (start) | /media/data/Unsorted/.watch/start/ |
| Logs | /media/data/Unsorted/.log/ |

## Key Settings

- Port: 50000
- Upload limit: 5200 KB/s
- DHT: auto
- SCGI socket: /tmp/rtorrent-rpc.socket (for web UI)
- Memory: 1800MB max

## NixOS Implementation

```nix
services.rtorrent = {
  enable = true;
  user = "torrents";
  group = "torrents";
  dataDir = "/media/data/Unsorted";
  downloadDir = "/media/data/Unsorted/.downloading";
  configText = ''
    # See rtorrent.rc for full config
    network.port_range.set = 50000-50000
    network.scgi.open_local = /run/rtorrent/rpc.socket
  '';
};
```

## Web UI

Currently using ruTorrent, but PLAN.md says to switch to Flood due to NixOS bugs with ruTorrent.

```nix
services.flood = {
  enable = true;
  host = "127.0.0.1";
  port = 3001;  # or whatever
};
```
