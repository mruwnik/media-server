# NFS Migration

## Files

- `exports` - Current NFS exports

## Exports

| Export | Path | Options |
|--------|------|---------|
| /export (pseudo-root) | NFSv4 root | ro, fsid=0 |
| /export/Films | /media/data/Films | ro |
| /export/Anime | /media/data/Anime | ro |
| /export/Music | /media/data/Music | ro |
| /export/Books | /media/data/Books | ro |
| /export/Serials | /media/data/Serials | ro |
| /export/Unsorted | /media/data/Unsorted | rw |
| /export/dan-backup | /media/data/backups/dan | rw, LAN only, anonuid=1000 |
| /export/nadia | /media/data/backups/nadia | rw |

## NixOS Implementation

NixOS doesn't use bind mounts to /export. Configure directly:

```nix
services.nfs.server = {
  enable = true;
  exports = ''
    /media/data/Films    *(ro,sync,no_subtree_check,insecure)
    /media/data/Anime    *(ro,sync,no_subtree_check,insecure)
    /media/data/Music    *(ro,sync,no_subtree_check,insecure)
    /media/data/backups/dan  192.168.0.0/24(rw,sync,no_subtree_check,all_squash,anonuid=1001,anongid=100)
  '';
};

networking.firewall.allowedTCPPorts = [ 2049 ];
```

## Client Mount

```bash
mount -t nfs4 192.168.0.198:/media/data/Music /mnt/music
```
