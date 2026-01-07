{ config, lib, pkgs, ... }:

let
  # Primary user name for SSH key path (matches users.nix)
  primaryUser = "dan";

  # Shell function to apply theme patches (used by both services)
  applyThemePatches = ''
    apply_theme_patches() {
      local blog_dir="$1"
      echo "Applying theme patches..."
      cp /etc/ahiru-blog/theme-patches/partials/head.html "$blog_dir/themes/cactus/layouts/partials/head.html"
      cp /etc/ahiru-blog/theme-patches/partials/footer.html "$blog_dir/themes/cactus/layouts/partials/footer.html"
      cp /etc/ahiru-blog/theme-patches/posts/single.html "$blog_dir/themes/cactus/layouts/posts/single.html"
      mkdir -p "$blog_dir/themes/cactus/layouts/notes"
      cp /etc/ahiru-blog/theme-patches/notes/single.html "$blog_dir/themes/cactus/layouts/notes/single.html"
    }
  '';
in
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
      ${applyThemePatches}

      BLOG_DIR="/var/www/ahiru"
      export GIT_SSH_COMMAND="ssh -i /home/${primaryUser}/.ssh/id_ed25519 -o UserKnownHostsFile=/root/.ssh/known_hosts"

      # Clone or pull
      if [ ! -d "$BLOG_DIR/.git" ]; then
        echo "Cloning ahiru-blog..."
        rm -rf "$BLOG_DIR"
        git clone --recurse-submodules git@github.com:mruwnik/ahiru-blog.git "$BLOG_DIR"
      fi

      apply_theme_patches "$BLOG_DIR"

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
      ${applyThemePatches}

      BLOG_DIR="/var/www/ahiru"
      export GIT_SSH_COMMAND="ssh -i /home/${primaryUser}/.ssh/id_ed25519 -o UserKnownHostsFile=/root/.ssh/known_hosts"

      if [ -d "$BLOG_DIR/.git" ]; then
        cd "$BLOG_DIR"
        git fetch origin
        LOCAL=$(git rev-parse HEAD)
        REMOTE=$(git rev-parse origin/main 2>/dev/null || git rev-parse origin/master)

        if [ "$LOCAL" != "$REMOTE" ]; then
          echo "Updates found, rebuilding..."
          git reset --hard "$REMOTE"
          git submodule update --init --recursive

          apply_theme_patches "$BLOG_DIR"

          hugo --minify
          chown -R nginx:nginx "$BLOG_DIR"
          echo "Blog updated"
        else
          echo "No updates"
        fi
      fi
    '';
  };

  # Theme patches for Hugo compatibility (deprecated analytics removed, custom layouts)
  environment.etc."ahiru-blog/theme-patches/partials/head.html".source = ../../static/theme-patches/partials/head.html;
  environment.etc."ahiru-blog/theme-patches/partials/footer.html".source = ../../static/theme-patches/partials/footer.html;
  environment.etc."ahiru-blog/theme-patches/posts/single.html".source = ../../static/theme-patches/posts/single.html;
  environment.etc."ahiru-blog/theme-patches/notes/single.html".source = ../../static/theme-patches/notes/single.html;

  # media.ahiru.pl - copy static files from this repo
  environment.etc."www/media/index.html" = {
    source = ../../static/media-index.html;
    mode = "0644";
  };
  environment.etc."www/media/img/bus.jpg" = {
    source = ../../static/media-img/bus.jpg;
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
      mkdir -p /media/data/www/media/img
      cp /etc/www/media/index.html /media/data/www/media/index.html
      cp /etc/www/media/img/bus.jpg /media/data/www/media/img/bus.jpg
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
