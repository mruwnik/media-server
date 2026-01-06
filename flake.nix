{
  description = "NixOS configuration for ahiru.pl home server (Raspberry Pi 4)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

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
