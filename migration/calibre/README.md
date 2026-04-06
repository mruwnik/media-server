# Calibre-web Migration

## Data Location

- Library: `/media/data/Books/`
- Calibre database: `/media/data/Books/metadata.db`

## Current Setup

- Port: 8123
- Proxied via nginx at media.ahiru.pl/books

## NixOS Implementation

```nix
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

# Ensure calibre user can access Books directory
users.users.calibre = {
  isSystemUser = true;
  group = "calibre";
  # Match old UID for file permissions
  uid = 1002;
};
users.groups.calibre.gid = 1004;
```

## Notes

The Books directory is owned by calibre:calibre (1002:1004).
Make sure NixOS calibre user has matching UID/GID or fix permissions.
