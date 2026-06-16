{
  description = "NixOS configuration for ahiru.pl home server (Raspberry Pi 4)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    # ⚠ TEMPORARY: last pre-curl-8.20 nixpkgs (rev 0c88e1f2, 2026-05-05), used
    # ONLY to pin rtorrent + libtorrent-rakshasa around the libtorrent epoll
    # busy-loop (rakshasa/libtorrent#722,#756). Remove together with
    # modules/services/rtorrent-curl8-pin.nix when upstream ships the fix.
    nixpkgs-rtorrent-pin.url = "github:NixOS/nixpkgs/0c88e1f2bdb93d5999019e99cb0e61e1fe2af4c5";

    raspberry-pi-nix = {
      url = "github:nix-community/raspberry-pi-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, raspberry-pi-nix, sops-nix, ... }@inputs: {
    # Full configuration with all services
    nixosConfigurations.ahiru = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        raspberry-pi-nix.nixosModules.raspberry-pi
        raspberry-pi-nix.nixosModules.sd-image
        sops-nix.nixosModules.sops
        ./hosts/ahiru
      ];
    };

    # Minimal base configuration for first-boot HDD installation
    nixosConfigurations.ahiru-base = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        raspberry-pi-nix.nixosModules.raspberry-pi
        raspberry-pi-nix.nixosModules.sd-image
        sops-nix.nixosModules.sops
        ./hosts/ahiru/base.nix
      ];
    };

    # Build images:
    #   Full:  nix build '.#images.ahiru'
    #   Base:  nix build '.#images.ahiru-base'
    images.ahiru = self.nixosConfigurations.ahiru.config.system.build.sdImage;
    images.ahiru-base = self.nixosConfigurations.ahiru-base.config.system.build.sdImage;
  };
}
