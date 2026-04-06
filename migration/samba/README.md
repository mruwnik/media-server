# Samba Migration

## Files

- `smb.conf` - Full Samba configuration

## Shares

| Share | Path | Access |
|-------|------|--------|
| Anime | /media/data/Anime/ | ftp-access group, rumun (read-only) |
| Books | /media/data/Books/ | (check smb.conf) |
| Films | /media/data/Films/ | (check smb.conf) |
| Music | /media/data/Music/ | (check smb.conf) |
| Serials | /media/data/Serials/ | (check smb.conf) |
| Unsorted | /media/data/Unsorted/ | (check smb.conf) |
| dan-backup | /media/data/backups/dan/ | (check smb.conf) |
| nadia | /media/data/backups/nadia/ | (check smb.conf) |

## Key Settings

- Workgroup: AHIRU
- Guest account: nobody
- Apple/macOS support: `fruit:aapl = yes`
- Default masks: 0664/0775

## NixOS Implementation

```nix
services.samba = {
  enable = true;
  openFirewall = true;  # Opens 139, 445
  settings = {
    global = {
      workgroup = "AHIRU";
      "server string" = "ahiru";
      # ...
    };
    Anime = {
      path = "/media/data/Anime";
      "read only" = "yes";
      "valid users" = "@ftp-access rumun";
    };
  };
};
```

## Users

Samba users need to be added with `smbpasswd -a <username>`.
The password database is separate from system passwords.
