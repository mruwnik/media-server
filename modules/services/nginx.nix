{ config, lib, pkgs, ... }:

let
  primaryEmail = config.ahiru.primaryUser.email;
in
{
  # Group for services that need to read htpasswd file
  users.groups.htpasswd-readers = {};

  # Add nginx to the htpasswd-readers group
  users.users.nginx.extraGroups = [ "htpasswd-readers" ];

  # ACME (Let's Encrypt) configuration
  security.acme = {
    acceptTerms = true;
    defaults.email = primaryEmail;
  };

  # Ports 80/443 defined in networking.nix

  # Shared htpasswd file - created by tmpfiles, populated by deploy-secrets.sh
  systemd.tmpfiles.rules = [
    "f /etc/shared-htpasswd 0640 root htpasswd-readers -"
  ];

  services.nginx = {
    enable = true;

    # Recommended settings
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    # Catch-all default server: reject requests that don't match a known vhost
    # (e.g. direct hits to the server's IP). Prevents nginx from borrowing
    # ahiru.pl's cert and serving its content to unknown-Host requests.
    virtualHosts."_default_" = {
      default = true;
      rejectSSL = true;
      locations."/".return = "444";
    };

    # ahiru.pl - Hugo static blog
    virtualHosts."ahiru.pl" = {
      enableACME = true;
      forceSSL = true;
      root = "/var/www/ahiru/public";

      locations."/" = {
        tryFiles = "$uri $uri/ =404";
        index = "index.html";
      };

      # Custom 404 page
      extraConfig = ''
        error_page 404 /404.html;
      '';

      # Local MCP server - /mcp (manages its own auth)
      locations."^~ /mcp" = {
        proxyPass = "http://127.0.0.1:3001";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_intercept_errors off;
        '';
      };

      # OAuth endpoints for MCP server (at root level due to fastmcp behavior)
      locations."/authorize" = {
        proxyPass = "http://127.0.0.1:3001/authorize";
        extraConfig = ''
          proxy_intercept_errors off;
        '';
      };
      locations."/token" = {
        proxyPass = "http://127.0.0.1:3001/token";
        extraConfig = ''
          proxy_intercept_errors off;
        '';
      };
      locations."/register" = {
        proxyPass = "http://127.0.0.1:3001/register";
        extraConfig = ''
          proxy_intercept_errors off;
        '';
      };
      locations."/login" = {
        proxyPass = "http://127.0.0.1:3001/login";
        extraConfig = ''
          proxy_intercept_errors off;
        '';
      };
      locations."/.well-known/" = {
        proxyPass = "http://127.0.0.1:3001/.well-known/";
        extraConfig = ''
          proxy_intercept_errors off;
        '';
      };
    };

    # differ.ahiru.pl - code review UI + MCP (proxies differ on :8576)
    # differ's own OAuth accepts everything by design, so nginx is the gate:
    # LAN sources (incl. hairpinned ones) get in by IP, anyone else needs the
    # shared htpasswd. MCP clients only work from the LAN — they'd send their
    # own Authorization header, which clobbers basic auth.
    virtualHosts."differ.ahiru.pl" = {
      enableACME = true;
      forceSSL = true;

      locations."/" = {
        proxyPass = "http://127.0.0.1:8576";
        proxyWebsockets = true;
        basicAuthFile = "/etc/shared-htpasswd";
        extraConfig = ''
          satisfy any;
          allow 127.0.0.1;
          allow 192.168.0.0/24;
          # LAN clients resolve differ.ahiru.pl to the WAN address and hairpin
          # through the router, which masquerades them AS the WAN address —
          # only inside traffic can ever have this source, so it's LAN too.
          # If the WAN IP changes this line goes stale (harmless: those
          # clients just fall back to the htpasswd prompt) — update it.
          allow 194.181.243.144;
          deny all;
          # SSE (/events) + streaming MCP responses: no buffering, and let
          # review sessions idle without nginx cutting the stream.
          proxy_buffering off;
          proxy_read_timeout 4h;
        '';
      };
    };

    # media.ahiru.pl - services portal
    virtualHosts."media.ahiru.pl" = {
      enableACME = true;
      forceSSL = true;
      root = "/var/www/media";

      # Static files
      locations."/" = {
        tryFiles = "$uri $uri/ =404";
        index = "index.html";
      };

      # Calibre-web - /books
      # Use calibre-web's built-in reverse-proxy support (ReverseProxied reads
      # X-Script-Name) so Flask's url_for() prefixes EVERY generated URL with
      # /books. This replaces the old sub_filter hack, which rewrote src="/ but
      # not srcset="/, leaving cover thumbnails (/cover/<id>/sm) un-prefixed and
      # 404ing — so the grid showed blank covers.
      locations."/books" = {
        return = "301 /books/";
      };
      locations."/books/" = {
        proxyPass = "http://127.0.0.1:8083/";
        proxyWebsockets = true;
        basicAuthFile = "/etc/shared-htpasswd";
        # NB: do NOT set Host / X-Forwarded-Host / X-Forwarded-For here —
        # recommendedProxySettings already includes them. Duplicating Host sends
        # two Host headers, which calibre-web's Tornado rejects ("Multiple host
        # headers not allowed") → 502. Only the calibre-specific headers belong
        # here; X-Scheme (not X-Forwarded-Proto) is what ReverseProxied reads.
        extraConfig = ''
          proxy_set_header X-Remote-User $remote_user;
          proxy_set_header X-Script-Name /books;
          proxy_set_header X-Scheme $scheme;
          # Allow large ebook uploads (default is 1M -> 413). Scanned PDFs can
          # be hundreds of MB. Also give calibre-web time to ingest/convert.
          client_max_body_size 1024m;
          proxy_read_timeout 600s;
        '';
      };

      # Radicale CalDAV - /radicale/
      locations."/radicale/" = {
        proxyPass = "http://127.0.0.1:5232/";
        extraConfig = ''
          proxy_set_header X-Script-Name /radicale;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header Host $host;
        '';
      };

      # Flood torrent UI - /torrents
      locations."/torrents" = {
        return = "301 /torrents/";
      };
      locations."/torrents/" = {
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;
        basicAuthFile = "/etc/shared-htpasswd";
      };

      # myMPD music UI - /music
      locations."/music" = {
        return = "301 /music/";
      };
      locations."/music/" = {
        proxyPass = "http://127.0.0.1:8080/";
        proxyWebsockets = true;
        basicAuthFile = "/etc/shared-htpasswd";
      };
    };
  };
}
