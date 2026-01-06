{ config, lib, pkgs, ... }:

{
  # ahiru.pl blog - auto-clone and build from git
  systemd.services.ahiru-blog = {
    description = "Clone and build ahiru.pl Hugo blog";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    path = [ pkgs.git pkgs.hugo pkgs.openssh ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
      Group = "root";
    };

    script = ''
      set -euo pipefail
      BLOG_DIR="/var/www/ahiru"

      # Clone or pull
      if [ ! -d "$BLOG_DIR/.git" ]; then
        echo "Cloning ahiru-blog..."
        rm -rf "$BLOG_DIR"
        git clone git@github.com:mruwnik/ahiru-blog.git "$BLOG_DIR"
      fi

      # Build with Hugo (in-place)
      cd "$BLOG_DIR"
      hugo --minify

      # Set permissions for nginx
      chown -R nginx:nginx "$BLOG_DIR"
      echo "Blog built successfully"
    '';
  };

  # Timer to rebuild blog every 5 minutes
  systemd.timers.ahiru-blog-update = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";  # Every 5 minutes
      Persistent = true;
    };
  };

  systemd.services.ahiru-blog-update = {
    description = "Update ahiru.pl blog";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = [ pkgs.git pkgs.hugo pkgs.openssh ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
    };

    script = ''
      set -euo pipefail
      BLOG_DIR="/var/www/ahiru"

      if [ -d "$BLOG_DIR/.git" ]; then
        cd "$BLOG_DIR"
        git fetch origin
        LOCAL=$(git rev-parse HEAD)
        REMOTE=$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/master)

        if [ "$LOCAL" != "$REMOTE" ]; then
          echo "Updates found, rebuilding..."
          git reset --hard "$REMOTE"
          hugo --minify
          chown -R nginx:nginx "$BLOG_DIR"
          echo "Blog updated"
        else
          echo "No updates"
        fi
      fi
    '';
  };

  # media.ahiru.pl - copy static index from this repo
  environment.etc."www/media/index.html" = {
    source = ../../static/media-index.html;
    mode = "0644";
  };

  # Ensure media directory exists and copy index.html there
  systemd.services.media-portal-setup = {
    description = "Set up media.ahiru.pl portal";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      mkdir -p /media/data/www/media
      cp /etc/www/media/index.html /media/data/www/media/index.html
      chown -R nginx:nginx /media/data/www/media
    '';
  };

  # Ensure directories exist
  systemd.tmpfiles.rules = [
    "d /var/www 0755 nginx nginx -"
    "d /media/data/www 0755 nginx nginx -"
    "d /media/data/www/media 0755 nginx nginx -"
  ];
}
