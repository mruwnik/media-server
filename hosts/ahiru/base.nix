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

  # Disable pipewire's libcamera plugin - incompatible with raspberry-pi-nix's
  # older libcamera fork (missing ControlId::vendor() and isArray() methods)
  nixpkgs.overlays = [
    (final: prev: {
      pipewire = prev.pipewire.overrideAttrs (old: {
        mesonFlags = (old.mesonFlags or []) ++ [
          "-Dlibcamera=disabled"
        ];
        buildInputs = builtins.filter (dep: dep != null && (dep.pname or "") != "libcamera") (old.buildInputs or []);
      });
    })
  ];

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
