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

    # Build SD/USB image: nix build '.#images.ahiru'
    images.ahiru = self.nixosConfigurations.ahiru.config.system.build.sdImage;
  };
}
