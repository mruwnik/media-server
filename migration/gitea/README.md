# Gitea -> Forgejo Migration

## Files

- `passwords.txt` - Admin credentials (git@ahiru.pl)
- `repos-list.txt` - List of repositories

## Data Location

- Repositories: `/media/data/git/repos/`
- Gitea data: `/media/data/git/data/`
- Binary: `/home/git/gitea` (standalone, not packaged)

## Current Setup

- Port: 3001
- Domain: git.ahiru.pl
- SSH: via main sshd (no separate port)

## Known Issues

From CONTEXT.md: "Gitea SSH routing (port conflict with router)"

## Migration Notes

PLAN.md specifies Forgejo (Gitea fork) instead of Gitea.
Forgejo is compatible with Gitea data - should be a drop-in replacement.

## NixOS Implementation

```nix
services.forgejo = {
  enable = true;
  user = "git";
  group = "git";
  stateDir = "/media/data/git";
  settings = {
    server = {
      DOMAIN = "git.ahiru.pl";
      ROOT_URL = "https://git.ahiru.pl/";
      HTTP_PORT = 3001;
    };
    repository = {
      ROOT = "/media/data/git/repos";
    };
  };
};

users.users.git = {
  isSystemUser = true;
  group = "git";
  home = "/media/data/git";
  uid = 1009;  # Match old UID
};
users.groups.git.gid = 1010;
```

## SSH Access

For SSH git clone, either:
1. Use Forgejo's built-in SSH server on a different port
2. Route through main SSH with command restriction
