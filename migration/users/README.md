# User/Group Migration

## Files

- `ids.txt` - Current user/group IDs

## User IDs

| User | UID | GID | Purpose |
|------|-----|-----|---------|
| dan | 1001 | 100 (users) | Main user |
| calibre | 1002 | 1004 | Calibre-web |
| torrents | 1003 | 1005 | rtorrent |
| radicale | 1005 | 1006 | Radicale |
| cryptpad | 1007 | 1008 | CryptPad |
| git | 1009 | 1010 | Gitea/Forgejo |

## NixOS Implementation

To preserve file permissions, match UIDs/GIDs:

```nix
users.users.dan = {
  isNormalUser = true;
  uid = 1001;
  extraGroups = [ "wheel" ];
};

users.users.calibre = {
  isSystemUser = true;
  uid = 1002;
  group = "calibre";
};
users.groups.calibre.gid = 1004;

users.users.torrents = {
  isSystemUser = true;
  uid = 1003;
  group = "torrents";
};
users.groups.torrents.gid = 1005;

users.users.radicale = {
  isSystemUser = true;
  uid = 1005;
  group = "radicale";
};
users.groups.radicale.gid = 1006;

users.users.git = {
  isSystemUser = true;
  uid = 1009;
  group = "git";
  home = "/media/data/git";
};
users.groups.git.gid = 1010;

# cryptpad - usually created by the service module
```

## Alternative: Fix Permissions

If you don't want to hardcode UIDs, after migration run:
```bash
chown -R calibre:calibre /media/data/Books
chown -R torrents:torrents /media/data/Unsorted
chown -R radicale:radicale /media/data/calendar
chown -R git:git /media/data/git
```
