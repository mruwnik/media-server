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

      # Calibre-web - /books (use sub_filter to rewrite absolute paths)
      locations."/books" = {
        return = "301 /books/";
      };
      locations."/books/" = {
        proxyPass = "http://127.0.0.1:8083/";
        proxyWebsockets = true;
        basicAuthFile = "/etc/shared-htpasswd";
        extraConfig = ''
          proxy_set_header X-Remote-User $remote_user;
          proxy_set_header Accept-Encoding "";
          sub_filter_once off;
          sub_filter_types text/html text/css application/javascript;
          sub_filter 'href="/' 'href="/books/';
          sub_filter 'src="/' 'src="/books/';
          sub_filter 'action="/' 'action="/books/';
          sub_filter 'url(/' 'url(/books/';
          sub_filter '"/static/' '"/books/static/';
          sub_filter '"/login' '"/books/login';
          sub_filter '"/logout' '"/books/logout';
          sub_filter '"/me' '"/books/me';
          sub_filter '"/admin' '"/books/admin';
          sub_filter '"/shelf' '"/books/shelf';
          sub_filter '"/book' '"/books/book';
          sub_filter '"/read' '"/books/read';
          sub_filter '"/ajax' '"/books/ajax';
          sub_filter '"/tasks' '"/books/tasks';
          proxy_redirect / /books/;
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
