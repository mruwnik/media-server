{ config, lib, pkgs, ... }:

let
  # git-shell has no per-repo ACLs, so the memory worker's key is pinned to notes.git.
  # sshd runs forced commands via the login shell (git-shell), which only execs
  # names from ~/git-shell-commands, hence the symlink below.
  notesOnly = pkgs.writeShellScript "git-notes-only" ''
    case "$SSH_ORIGINAL_COMMAND" in
      "git-upload-pack 'dan/notes.git'" | "git-receive-pack 'dan/notes.git'" | \
      "git-upload-pack '~/dan/notes.git'" | "git-receive-pack '~/dan/notes.git'")
        exec ${pkgs.git}/bin/git-shell -c "$SSH_ORIGINAL_COMMAND" ;;
    esac
    echo "this key may only fetch/push dan/notes.git" >&2
    exit 1
  '';
in
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
      ''restrict,command="notes-only" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ2QkurKfikfXCarrSn0GGZ1V39hIlXfqB0EmkMd03Ko memory@ahiru.pl''
    ];
  };
  users.groups.git = {};

  # Ensure git home directory exists
  systemd.tmpfiles.rules = [
    "d /media/data/git/repos 0755 git git -"
  ];

  # Not tmpfiles: it refuses the dan→git ownership transition under /media/data
  system.activationScripts.gitShellCommands = lib.stringAfter [ "users" ] ''
    install -d -o root -g root -m 0755 /media/data/git/repos/git-shell-commands
    ln -sfn ${notesOnly} /media/data/git/repos/git-shell-commands/notes-only
  '';

  # Git package available system-wide
  environment.systemPackages = [ pkgs.git ];
}
