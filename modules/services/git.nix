{ config, lib, pkgs, ... }:

{
  # ============================================================
  # Git - SSH-only git hosting with git-shell
  # ============================================================
  # Access: git@git.ahiru.pl:repo.git
  # No web UI - simple bare repos via SSH

  # Git user with restricted git-shell
  users.users.git = {
    isSystemUser = true;
    group = "git";
    home = "/media/data/git/repos";
    shell = "${pkgs.git}/bin/git-shell";
    description = "Git repository hosting";
    openssh.authorizedKeys.keys = [
      # Dan's SSH key (same as main user)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN/7ZMH3Q2QQQFD6Ugtv8Lii2WTdYV3GM0aYa5Bu+Bvw me@ahiru.pl"
    ];
  };
  users.groups.git = {};

  # Ensure git home directory exists
  systemd.tmpfiles.rules = [
    "d /media/data/git/repos 0755 git git -"
  ];

  # Git package available system-wide
  environment.systemPackages = [ pkgs.git ];
}
