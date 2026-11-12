# Minimal bootable config for first-boot HDD installation
# After HDD boot, run: sudo nixos-rebuild switch --flake '.#ahiru'
{ config, pkgs, inputs, ... }:

{
  imports = [
    ./hardware.nix
    ../../modules/common/networking.nix
    ../../modules/common/users.nix
    ../../modules/common/first-boot-install.nix
  ];

  networking.hostName = "ahiru";

  nixpkgs.config.allowUnfree = true;

  # Relax calibre-web's `requests<2.33.0` upper bound: nixpkgs ships 2.33.1
  # and the runtime check otherwise fails the build.
  nixpkgs.overlays = [
    (final: prev: {
      calibre-web = prev.calibre-web.overrideAttrs (old: {
        pythonRelaxDeps = (old.pythonRelaxDeps or []) ++ [ "requests" ];
      });
      # Password lives in /etc/msmtprc; dropping keyring keeps libsecret/gjs (compiled on every bump) off the Pi.
      msmtp = prev.msmtp.override { withKeyring = false; };
    })
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # A cache miss that compiles in parallel exhausts 4GB RAM and hangs the Pi.
  nix.settings.max-jobs = 1;
  nix.settings.cores = 2;

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
      # Otherwise PAM still offers password prompts to brute-forcers.
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  system.stateVersion = "24.11";
}
