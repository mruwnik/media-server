# nginx Migration

## Files

- `htpasswd` - Basic auth credentials (dan, nadia) - used by media.ahiru.pl
- `ahiru.pl.conf` - Main domain config
- `git.ahiru.pl.conf` - Gitea reverse proxy
- `media.conf` - Media services (calibre, radicale, torrents, rompr)
- `cryptpad.conf` - CryptPad (docs.ahiru.pl + secure.docs.ahiru.pl)
- `www/` - Static web content

## Domains & SSL

| Domain | Purpose | Cert |
|--------|---------|------|
| ahiru.pl | Main landing | docs.ahiru.pl cert |
| media.ahiru.pl | /books, /radicale, /music, /torrents | separate cert |
| git.ahiru.pl | Gitea | separate cert |
| docs.ahiru.pl | CryptPad main | shared with secure.* |
| secure.docs.ahiru.pl | CryptPad sandbox | shared with docs.* |

## NixOS Implementation

In NixOS, use `security.acme` for certs and `services.nginx.virtualHosts`:

```nix
security.acme = {
  acceptTerms = true;
  defaults.email = "me@ahiru.pl";
};

services.nginx.virtualHosts."media.ahiru.pl" = {
  enableACME = true;
  forceSSL = true;
  locations."/books".proxyPass = "http://127.0.0.1:8083/";
  # ...
};
```

## Credentials

htpasswd uses Apache MD5 format ($apr1$). For NixOS nginx basic auth:
- Option 1: Copy htpasswd file and reference it
- Option 2: Use `services.nginx.virtualHosts.<name>.basicAuthFile`
