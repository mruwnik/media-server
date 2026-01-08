{ config, lib, pkgs, ... }:

{
  # ============================================================
  # Radicale - CalDAV/CardDAV server
  # ============================================================

  # Radicale needs to read htpasswd file
  users.users.radicale.extraGroups = [ "htpasswd-readers" ];

  services.radicale = {
    enable = true;
    settings = {
      server = {
        hosts = [ "127.0.0.1:5232" ];
      };
      auth = {
        type = "htpasswd";
        htpasswd_filename = "/etc/shared-htpasswd";
        htpasswd_encryption = "md5";  # apr1 hashes
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

  # Ensure calendar directory exists with correct permissions
  systemd.tmpfiles.rules = [
    "d /media/data/calendar 0750 radicale radicale -"
    "d /media/data/calendar/collection-root 0750 radicale radicale -"
  ];
}
