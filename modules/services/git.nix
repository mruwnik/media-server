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
    home = "/media/data/git";
    shell = "${pkgs.git}/bin/git-shell";
    description = "Git repository hosting";
    openssh.authorizedKeys.keys = [
      # Dan's SSH key (same as main user)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMCRsyplB7GDFE9GarBla6C0N9lD0wmu7UaSFQQ2Pjz/"
    ];
  };
  users.groups.git = {};

  # Ensure git home directory exists
  systemd.tmpfiles.rules = [
    "d /media/data/git 0755 git git -"
  ];

  # Git package available system-wide
  environment.systemPackages = [ pkgs.git ];
}
