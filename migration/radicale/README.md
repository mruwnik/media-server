# Radicale Migration

## Files

- `users-list.txt` - List of calendar users

## Data Location

- Collections: `/media/data/calendar/collection-root/`
- Users: dan, nadia

## Current Setup

- Port: 5232
- Proxied via nginx at media.ahiru.pl/radicale/
- Authentication: commented out in nginx (was basic auth)

## Known Issues

From CONTEXT.md: "iOS CalDAV path quirks with Radicale"

## NixOS Implementation

```nix
services.radicale = {
  enable = true;
  settings = {
    server = {
      hosts = [ "127.0.0.1:5232" ];
    };
    auth = {
      type = "htpasswd";
      htpasswd_filename = "/etc/radicale/htpasswd";
      htpasswd_encryption = "md5";  # or bcrypt
    };
    storage = {
      filesystem_folder = "/media/data/calendar/collection-root";
    };
  };
};

# Ensure radicale user can access calendar directory
users.users.radicale = {
  isSystemUser = true;
  group = "radicale";
  uid = 1005;  # Match old UID
};
users.groups.radicale.gid = 1006;
```

## Client URLs

- CalDAV: `https://media.ahiru.pl/radicale/dan/`
- CardDAV: same pattern

## iOS Setup

iOS requires the full principal URL. Test with:
`https://media.ahiru.pl/radicale/dan/calendar.ics/`
