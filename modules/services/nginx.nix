{ lib, pkgs, ... }:

{
  # ACME (Let's Encrypt) configuration
  security.acme = {
    acceptTerms = true;
    defaults.email = "tojad99@gmail.com";
  };

  # Ports 80/443 defined in networking.nix

  # Basic auth credentials (htpasswd format - passwords are hashed)
  environment.etc."nginx/htpasswd" = {
    text = ''
      dan:$apr1$7bIsm34C$SZzlRphUURQABM5eMTtO41
      nadia:$apr1$DQ.OxmB2$w4zbBDza2fotuGf5IHWjh/
    '';
    mode = "0640";
    user = "nginx";
    group = "nginx";
  };

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
    };

    # media.ahiru.pl - services portal
    virtualHosts."media.ahiru.pl" = {
      enableACME = true;
      forceSSL = true;
      root = "/media/data/www/media";

      # Static files
      locations."/" = {
        tryFiles = "$uri $uri/ =404";
        index = "index.html";
      };

      # Calibre-web - /books
      locations."/books" = {
        proxyPass = "http://127.0.0.1:8083";
        proxyWebsockets = true;
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
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;
        basicAuthFile = "/etc/nginx/htpasswd";
      };

      # myMPD music UI - /music
      locations."/music" = {
        proxyPass = "http://127.0.0.1:8080";
        proxyWebsockets = true;
        basicAuthFile = "/etc/nginx/htpasswd";
      };
    };
  };
}
