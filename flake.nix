{
  description = "NixOS configuration for ahiru.pl home server (Raspberry Pi 4)";

  inputs = {
    # Pi kernel/firmware/bootloader. Our nixpkgs follows theirs (never the
    # reverse) so the vendor kernel matches their cachix build instead of
    # rebuilding on the Pi for ~8h after every toolchain change.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
    nixpkgs.follows = "nixos-raspberrypi/nixpkgs";

    # ⚠ TEMPORARY: last pre-curl-8.20 nixpkgs (rev 0c88e1f2, 2026-05-05), used
    # ONLY to pin rtorrent + libtorrent-rakshasa around the libtorrent epoll
    # busy-loop (rakshasa/libtorrent#722,#756). Remove together with
    # modules/services/rtorrent-curl8-pin.nix when upstream ships the fix.
    nixpkgs-rtorrent-pin.url = "github:NixOS/nixpkgs/0c88e1f2bdb93d5999019e99cb0e61e1fe2af4c5";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-raspberrypi, sops-nix, ... }@inputs: {
    # Full configuration with all services
    nixosConfigurations.ahiru = nixos-raspberrypi.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        nixos-raspberrypi.nixosModules.raspberry-pi-4.base
        sops-nix.nixosModules.sops
        ./hosts/ahiru
      ];
    };

    # Minimal base configuration for first-boot HDD installation
    nixosConfigurations.ahiru-base = nixos-raspberrypi.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        nixos-raspberrypi.nixosModules.raspberry-pi-4.base
        nixos-raspberrypi.nixosModules.sd-image
        sops-nix.nixosModules.sops
        ./hosts/ahiru/base.nix
      ];
    };

    # Build image: nix build '.#images.ahiru-base'
    images.ahiru-base = self.nixosConfigurations.ahiru-base.config.system.build.sdImage;
  };
}
