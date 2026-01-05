{ config, lib, pkgs, ... }:

{
  # ============================================================
  # Radicale - CalDAV/CardDAV server
  # ============================================================
  services.radicale = {
    enable = true;
    settings = {
      server = {
        hosts = [ "127.0.0.1:5232" ];
      };
      auth = {
        type = "htpasswd";
        htpasswd_filename = "/etc/radicale/htpasswd";
        htpasswd_encryption = "plain";  # Use plain for compatibility
      };
      storage = {
        filesystem_folder = "/media/data/calendar/collection-root";
      };
      # Logging
      logging = {
        level = "warning";
      };
    };
  };

  # Radicale htpasswd file (same users as nginx)
  environment.etc."radicale/htpasswd" = {
    text = ''
      dan:$apr1$7bIsm34C$SZzlRphUURQABM5eMTtO41
      nadia:$apr1$DQ.OxmB2$w4zbBDza2fotuGf5IHWjh/
    '';
    mode = "0640";
    user = "radicale";
    group = "radicale";
  };

  # Ensure calendar directory exists with correct permissions
  systemd.tmpfiles.rules = [
    "d /media/data/calendar 0750 radicale radicale -"
    "d /media/data/calendar/collection-root 0750 radicale radicale -"
  ];
}
