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
  # Relax calibre-web's `requests<2.33.0` upper bound: nixpkgs ships 2.33.1
  # and the runtime check otherwise fails the build.
  nixpkgs.overlays = [
    (final: prev: {
      pipewire = prev.pipewire.overrideAttrs (old: {
        mesonFlags = (old.mesonFlags or []) ++ [
          "-Dlibcamera=disabled"
        ];
        buildInputs = builtins.filter (dep: dep != null && (dep.pname or "") != "libcamera") (old.buildInputs or []);
      });
      calibre-web = prev.calibre-web.overrideAttrs (old: {
        pythonRelaxDeps = (old.pythonRelaxDeps or []) ++ [ "requests" ];
      });
      # Pi 4 is too slow for upstream gjs's 30s per-test timeout
      # (CommandLine, Internal API tests). Skip check phase and tell
      # meson not to require GTK at configure time (which is only there
      # for the now-skipped tests).
      gjs = prev.gjs.overrideAttrs (old: {
        doCheck = false;
        mesonFlags = (old.mesonFlags or []) ++ [ "-Dskip_gtk_tests=true" ];
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
