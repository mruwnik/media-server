{ config, pkgs, inputs, ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/common/networking.nix
    ../../modules/common/users.nix
    # Services (added incrementally)
    ../../modules/services/nginx.nix
    ../../modules/services/storage.nix
    ../../modules/services/torrent.nix
    # ../../modules/services/media.nix
    # ../../modules/services/calendar.nix
    # ../../modules/services/git.nix
    # ../../modules/services/dns.nix
  ];

  networking.hostName = "ahiru";

  nixpkgs.config.allowUnfree = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  time.timeZone = "Europe/Warsaw";

  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    tmux
    curl
    wget
  ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  system.stateVersion = "24.11";
}
